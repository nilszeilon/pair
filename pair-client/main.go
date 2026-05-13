package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/creack/pty"
	"golang.org/x/term"
)

const serverPort = "4242"

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	// Flags
	if os.Args[1] == "--version" || os.Args[1] == "-v" {
		fmt.Println("pair 1.0.0 (Go client)")
		return
	}

	switch os.Args[1] {
	case "connect":
		if len(os.Args) < 3 {
			fmt.Fprintln(os.Stderr, "Usage: pair connect <host>")
			os.Exit(1)
		}
		connect(os.Args[2])
	case "server":
		fmt.Fprintln(os.Stderr, "Server is Elixir. Run: cd pair && mix pair server")
		os.Exit(1)
	case "list":
		list()
	case "join":
		if len(os.Args) < 3 {
			fmt.Fprintln(os.Stderr, "Usage: pair join <name>")
			os.Exit(1)
		}
		join(os.Args[2])
	case "stop":
		if len(os.Args) < 3 {
			fmt.Fprintln(os.Stderr, "Usage: pair stop <name>")
			os.Exit(1)
		}
		stop(os.Args[2])
	case "browse":
		browse()
	case "remote":
		// pair remote pi - explicitly remote, requires pair connect
		if len(os.Args) < 3 {
			fmt.Fprintln(os.Stderr, "Usage: pair remote <agent> [path]")
			os.Exit(1)
		}
		startRemote(os.Args[2:])
	default:
		// pair pi, pair claude, pair pi /path
		start(os.Args[1:])
	}
}

func start(args []string) {
	// Local: run in cwd, server binds to Tailscale IP (or 127.0.0.1)
	// Phone on tailnet can access the browser URL, cafe wifi cannot.
	startSession(args, serverHost(), serverHost(), false)
}

func startRemote(args []string) {
	host := remoteHost()
	if host == "" {
		fmt.Fprintln(os.Stderr, "No remote server configured.")
		fmt.Fprintln(os.Stderr, "  pair connect <host>  - set the remote server")
		os.Exit(1)
	}
	startSession(args, host, host, true)
}

func startSession(args []string, connectHost, displayHost string, isRemote bool) {
	agent := strings.Join(args, " ")

	var rootPath string
	if isRemote {
		cwd, _ := os.Getwd()
		rootPath = "/tmp/pair-sessions/" + filepath.Base(cwd)
	} else {
		if len(args) > 1 {
			rootPath = args[1]
		} else {
			rootPath, _ = os.Getwd()
		}
	}

	// Build request
	body := map[string]interface{}{
		"root_path": rootPath,
		"env":       map[string]string{},
		"agent":     agent,
		"host":      displayHost,
	}
	bodyJSON, _ := json.Marshal(body)

	apiURL := fmt.Sprintf("http://%s:%s/sessions", connectHost, serverPort)

	resp, err := http.Post(apiURL, "application/json", bytes.NewReader(bodyJSON))
	if err != nil {
		if !isRemote {
			fmt.Println("Server not running - starting it now...")
			if err := ensureServerRunning(); err != nil {
				fmt.Fprintf(os.Stderr, "Failed to start server: %v\n", err)
				fmt.Fprintf(os.Stderr, "Run 'pair server' manually or check Elixir installation.\n")
				os.Exit(1)
			}
			resp, err = http.Post(apiURL, "application/json", bytes.NewReader(bodyJSON))
			if err != nil {
				fmt.Fprintf(os.Stderr, "Server started but still unreachable at %s:%s\n", connectHost, serverPort)
				os.Exit(1)
			}
		} else {
			fmt.Fprintf(os.Stderr, "Failed to reach server at %s:%s\n", connectHost, serverPort)
			fmt.Fprintf(os.Stderr, "Is the orchestrator running? Run: pair server\n")
			os.Exit(1)
		}
	}
	defer resp.Body.Close()

	var result map[string]interface{}
	respBody, _ := io.ReadAll(resp.Body)
	json.Unmarshal(respBody, &result)

	id, _ := result["id"].(string)
	url2, _ := result["url"].(string)

	// Clean one-line startup message
	project := filepath.Base(rootPath)
	if isRemote {
		fmt.Printf("\n%s → %s:%s  │  %s\n", agent, connectHost, rootPath, url2)
		fmt.Printf("Close terminal to disconnect (session stays alive)\n\n")
	} else {
		fmt.Printf("\n%s → %s  │  %s\n", agent, project, url2)
		if os.Getenv("TMUX") != "" {
			fmt.Printf("Ctrl+B s to switch sessions, Ctrl+B d to detach\n")
		}
		fmt.Println()
	}

	if !isRemote {
		// Local: attach or switch to tmux session
		if os.Getenv("PAIR_NO_EXEC") == "1" {
			fmt.Printf("\ntmux attach -t pair-%s\n", id)
			fmt.Printf("Browser: %s\n", url2)
			openBrowser(url2)
			os.Exit(0)
		}
		tmuxPath, _ := exec.LookPath("tmux")
		if os.Getenv("TMUX") != "" {
			// Already in tmux - switch client to the pair session
			// Navigate back with Ctrl+B s (choose session)
			cmd := exec.Command("sh", "-c",
				fmt.Sprintf("while ! tmux has-session -t pair-%s 2>/dev/null; do sleep 0.2; done; tmux switch-client -t pair-%s", id, id))
			cmd.Run()
			os.Exit(0)
		}
		syscall.Exec(tmuxPath, []string{"tmux", "attach", "-t", "pair-" + id}, os.Environ())
		return
	}

	// Remote: proxy SSH session with file upload detection
	home, _ := os.UserHomeDir()
	keyPath := filepath.Join(home, ".ssh/pair")
	sshArgs := []string{"-tt", "-o", "StrictHostKeyChecking=no"}
	if _, err := os.Stat(keyPath); err == nil {
		sshArgs = append(sshArgs, "-i", keyPath)
	}

	dest := connectHost
	if !strings.Contains(dest, "@") {
		dest = "root@" + dest
	}
	sshArgs = append(sshArgs, dest, "tmux", "attach", "-t", "pair-"+id)
	fmt.Printf("\nBrowser: %s\n", url2)

	sshPath, _ := exec.LookPath("ssh")
	if os.Getenv("PAIR_NO_EXEC") == "1" {
		openBrowser(url2)
		os.Exit(0)
	}

	proxyRemoteSession(sshPath, sshArgs, connectHost)
}

func join(name string) {
	// Search both local and remote for a matching session
	s := findSession(name)
	if s == nil {
		fmt.Fprintf(os.Stderr, "Session '%s' not found.\n", name)
		os.Exit(1)
	}
	joinSession(*s)
}

func findSession(name string) *session {
	all := fetchAllSessions()

	// Exact match first
	for i := range all {
		if all[i].ID == name {
			return &all[i]
		}
	}

	// Partial match
	var matches []session
	for _, s := range all {
		if strings.Contains(s.ID, name) {
			matches = append(matches, s)
		}
	}

	if len(matches) == 1 {
		return &matches[0]
	}

	if len(matches) > 1 {
		fmt.Fprintf(os.Stderr, "Multiple sessions match '%s':\n", name)
		for _, m := range matches {
			fmt.Fprintf(os.Stderr, "  %s  (%s)\n", m.ID, m.Server)
		}
		os.Exit(1)
	}

	return nil
}

func list() {
	allSessions := fetchAllSessions()

	if len(allSessions) == 0 {
		fmt.Println("No active sessions.")
		return
	}

	for _, s := range allSessions {
		fmt.Printf("  %s  %s  %s\n", s.Agent, s.ID, s.Server)
		fmt.Printf("  %s\n\n", s.URL)
	}
}

// fetchAllSessions fetches sessions from both local and remote servers.
func fetchAllSessions() []session {
	var all []session

	// Local server
	if sessions := fetchSessionsFrom(serverHost()); sessions != nil {
		for i := range sessions {
			sessions[i].Server = "local"
		}
		all = append(all, sessions...)
	}

	// Remote server (if configured)
	if rh := remoteHost(); rh != "" && rh != serverHost() {
		if sessions := fetchSessionsFrom(rh); sessions != nil {
			for i := range sessions {
				sessions[i].Server = rh
			}
			all = append(all, sessions...)
		}
	}

	return all
}

func fetchSessionsFrom(host string) []session {
	resp, err := http.Get(fmt.Sprintf("http://%s:%s/sessions", host, serverPort))
	if err != nil {
		return nil
	}
	defer resp.Body.Close()

	var sessions []session
	json.NewDecoder(resp.Body).Decode(&sessions)
	return sessions
}

func stop(name string) {
	s := findSession(name)
	if s == nil {
		fmt.Fprintf(os.Stderr, "Session '%s' not found.\n", name)
		os.Exit(1)
	}
	stopSession(*s)
}

func stopOnServer(name, host string) {
	// Show what we're stopping
	resp, _ := http.Get(fmt.Sprintf("http://%s:%s/session/%s", host, serverPort, name))
	if resp != nil && resp.StatusCode == 200 {
		var state map[string]interface{}
		json.NewDecoder(resp.Body).Decode(&state)
		resp.Body.Close()
		agent, _ := state["agent"].(string)
		rootPath, _ := state["root_path"].(string)
		fmt.Printf("Stopping %s in %s\n", agent, filepath.Base(rootPath))
	}

	req, _ := http.NewRequest("DELETE", fmt.Sprintf("http://%s:%s/session/%s", host, serverPort, name), nil)
	_, err := http.DefaultClient.Do(req)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("Stopped.\n")
}

func stopSession(s session) {
	stopOnServer(s.ID, s.Server)
}

func joinSession(s session) {
	if s.Server == "local" || s.Server == "127.0.0.1" {
		tmuxPath, _ := exec.LookPath("tmux")
		if os.Getenv("TMUX") != "" {
			cmd := exec.Command("sh", "-c",
				fmt.Sprintf("while ! tmux has-session -t pair-%s 2>/dev/null; do sleep 0.2; done; tmux switch-client -t pair-%s", s.ID, s.ID))
			cmd.Run()
			os.Exit(0)
		}
		syscall.Exec(tmuxPath, []string{"tmux", "attach", "-t", "pair-" + s.ID}, os.Environ())
		return
	}

	// Remote: use the session's server
	joinRemote(s.ID, s.Server)
}

func joinRemote(name, host string) {
	home, _ := os.UserHomeDir()
	keyPath := filepath.Join(home, ".ssh/pair")
	sshArgs := []string{"-tt", "-o", "StrictHostKeyChecking=no"}
	if _, err := os.Stat(keyPath); err == nil {
		sshArgs = append(sshArgs, "-i", keyPath)
	}

	dest := host
	if !strings.Contains(dest, "@") {
		dest = "root@" + dest
	}

	sshArgs = append(sshArgs, dest, "tmux", "attach", "-t", "pair-"+name)

	fmt.Printf("Connecting to %s ...\n", host)

	sshPath, _ := exec.LookPath("ssh")
	if os.Getenv("PAIR_NO_EXEC") == "1" {
		os.Exit(0)
	}

	proxyRemoteSession(sshPath, sshArgs, host)
}

func connect(host string) {
	home, _ := os.UserHomeDir()
	configDir := filepath.Join(home, ".pair")
	os.MkdirAll(configDir, 0700)
	os.WriteFile(filepath.Join(configDir, "host"), []byte(host+"\n"), 0600)
	fmt.Printf("Server set to %s\n", host)
}

// ── PTY proxy with file upload detection ─────────────────────────

func proxyRemoteSession(sshPath string, sshArgs []string, host string) {
	oldState, err := term.MakeRaw(int(os.Stdin.Fd()))
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to set raw mode: %v\n", err)
		os.Exit(1)
	}
	defer term.Restore(int(os.Stdin.Fd()), oldState)

	cmd := exec.Command(sshPath, sshArgs...)
	winSize, err := pty.GetsizeFull(os.Stdin)
	if err != nil {
		winSize = &pty.Winsize{Rows: 24, Cols: 80}
	}
	ptyFile, err := pty.StartWithSize(cmd, &pty.Winsize{
		Rows: uint16(winSize.Rows),
		Cols: uint16(winSize.Cols),
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to start SSH: %v\n", err)
		os.Exit(1)
	}
	defer ptyFile.Close()

	winCh := make(chan os.Signal, 1)
	signal.Notify(winCh, syscall.SIGWINCH)
	defer signal.Stop(winCh)
	go func() {
		for range winCh {
			if ws, err := pty.GetsizeFull(os.Stdin); err == nil {
				pty.Setsize(ptyFile, &pty.Winsize{Rows: uint16(ws.Rows), Cols: uint16(ws.Cols)})
			}
		}
	}()

	done := make(chan struct{}, 2)

	go func() {
		io.Copy(os.Stdout, ptyFile)
		done <- struct{}{}
	}()

	go func() {
		proxyStdinBracketed(ptyFile, host)
		done <- struct{}{}
	}()

	<-done
	cmd.Process.Kill()
}

var (
	pasteStart = []byte("\x1b[200~")
	pasteEnd   = []byte("\x1b[201~")
)

// proxyStdinBracketed forwards input to PTY immediately. Only buffers content
// between bracketed paste markers (\e[200~ ... \e[201~) to scan for file paths.
// All other input passes instantly - no byte-by-byte matching, no ESC delays.
func proxyStdinBracketed(ptyFile *os.File, host string) {
	buf := make([]byte, 32768)
	var pending []byte // incomplete paste awaiting end marker

	for {
		n, err := os.Stdin.Read(buf)
		if err != nil {
			return
		}
		data := append(pending, buf[:n]...)
		pending = nil

		for len(data) > 0 {
			startIdx := bytes.Index(data, pasteStart)
			if startIdx == -1 {
				ptyFile.Write(data)
				break
			}

			// Forward everything before paste start
			ptyFile.Write(data[:startIdx])
			data = data[startIdx+len(pasteStart):]

			// Find paste end
			endIdx := bytes.Index(data, pasteEnd)
			if endIdx == -1 {
				// Paste incomplete - save for next read
				pending = append(pending, pasteStart...)
				pending = append(pending, data...)
				if len(pending) > 1<<20 { // 1MB limit - safety valve
					ptyFile.Write(pending)
					pending = nil
				}
				break
			}

			// Complete paste: scan content for file paths
			content := data[:endIdx]
			data = data[endIdx+len(pasteEnd):]

			replaced := scanAndUploadPaths(content, host)

			// Re-wrap in markers so remote terminal handles paste correctly
			ptyFile.Write(pasteStart)
			ptyFile.Write(replaced)
			ptyFile.Write(pasteEnd)
		}
	}
}

func scanAndUploadPaths(line []byte, host string) []byte {
	s := string(line)
	var result strings.Builder
	i := 0
	for i < len(s) {
		slashIdx := strings.Index(s[i:], "/")
		if slashIdx == -1 {
			result.WriteString(s[i:])
			break
		}
		slashIdx += i
		result.WriteString(s[i:slashIdx])

		// Scan to end of path, handling escaped spaces and quotes
		end := slashIdx + 1
		escaped := false
		for end < len(s) {
			c := s[end]
			if escaped {
				escaped = false
				end++
				continue
			}
			if c == '\\' {
				escaped = true
				end++
				continue
			}
			if c == ' ' || c == '\r' || c == '\n' || c == '\t' {
				break
			}
			end++
		}

		candidate := s[slashIdx:end]

		// Try the raw path first, then unescape backslashes
		resolved := candidate
		if _, err := os.Stat(resolved); err != nil {
			// Try with backslashes removed (unescape spaces)
			unescaped := strings.ReplaceAll(candidate, "\\ ", " ")
			if _, err := os.Stat(unescaped); err == nil {
				resolved = unescaped
			}
		}

		if info, err := os.Stat(resolved); err == nil && !info.IsDir() && len(resolved) > 1 {
			if remotePath := uploadFileForProxy(resolved, host); remotePath != "" {
				result.WriteString(remotePath)
			} else {
				result.WriteString(candidate)
			}
		} else {
			result.WriteString(candidate)
		}
		i = end
	}
	return []byte(result.String())
}

func uploadFileForProxy(localPath, host string) string {
	filename := filepath.Base(localPath)
	// Sanitize: replace spaces so the remote path doesn't need quoting
	safeName := strings.ReplaceAll(filename, " ", "_")
	remotePath := "/tmp/pair-uploads/" + safeName
	dest := host
	if !strings.Contains(dest, "@") {
		dest = "root@" + dest
	}
	home, _ := os.UserHomeDir()
	keyPath := filepath.Join(home, ".ssh/pair")
	scpArgs := []string{"-o", "StrictHostKeyChecking=no", "-q"}
	if _, err := os.Stat(keyPath); err == nil {
		scpArgs = append(scpArgs, "-i", keyPath)
	}
	exec.Command("ssh", append(scpArgs, dest, "mkdir -p /tmp/pair-uploads")...).Run()
	cmd := exec.Command("scp", append(scpArgs, localPath, dest+":"+remotePath)...)
	if err := cmd.Run(); err != nil {
		return ""
	}
	return remotePath
}

func serverHost() string {
	// Local: Tailscale IP if available, else localhost
	if ip := tailscaleIP(); ip != "" {
		return ip
	}
	return "127.0.0.1"
}

func remoteHost() string {
	if h := os.Getenv("PAIR_HOST"); h != "" {
		return h
	}
	home, _ := os.UserHomeDir()
	data, err := os.ReadFile(filepath.Join(home, ".pair", "host"))
	if err == nil {
		return strings.TrimSpace(string(data))
	}
	return ""
}

func tailscaleIP() string {
	cmd := exec.Command("tailscale", "ip", "-4")
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	// Take last line — tailscale may print warnings to stderr
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	return strings.TrimSpace(lines[len(lines)-1])
}

// findPairProject locates the pair Elixir project directory.
func findPairProject() string {
	// Walk up from cwd looking for mix.exs with "Pair" in it
	dir, _ := os.Getwd()
	for dir != "/" && dir != "." {
		mixFile := filepath.Join(dir, "mix.exs")
		if data, err := os.ReadFile(mixFile); err == nil {
			if strings.Contains(string(data), "Pair") {
				return dir
			}
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}

	// Fallback: check recorded project dir from install.sh
	home, _ := os.UserHomeDir()
	if data, err := os.ReadFile(filepath.Join(home, ".pair", "project")); err == nil {
		recordedDir := strings.TrimSpace(string(data))
		pairDir := filepath.Join(recordedDir, "pair")
		if _, err := os.Stat(filepath.Join(pairDir, "mix.exs")); err == nil {
			return pairDir
		}
	}

	// Fallback: check common locations
	candidates := []string{
		filepath.Join(home, "dev", "pair", "pair"),
		filepath.Join(home, "dev", "pair"),
		filepath.Join(home, "dev", "everywhere", "pair"),
		filepath.Join(home, "pair"),
		"/usr/local/lib/pair",
	}
	for _, d := range candidates {
		if _, err := os.Stat(filepath.Join(d, "mix.exs")); err == nil {
			return d
		}
	}
	return ""
}

// ensureServerRunning starts the pair Elixir server if it's not already running.
func ensureServerRunning() error {
	// Check if already running on the right IP
	bind := serverHost() // Tailscale IP or 127.0.0.1
	if resp, err := http.Get(fmt.Sprintf("http://%s:%s/health", bind, serverPort)); err == nil {
		resp.Body.Close()
		return nil
	}

	projectDir := findPairProject()
	if projectDir == "" {
		return fmt.Errorf("pair project not found - cd into the pair directory or clone it to ~/dev/pair")
	}

	mixPath, err := exec.LookPath("mix")
	if err != nil {
		return fmt.Errorf("Elixir/mix not found in PATH - install Elixir first")
	}

	// Server auto-detects Tailscale IP — no BIND needed
	cmd := exec.Command(mixPath, "pair", "server")
	cmd.Dir = projectDir
	cmd.Stdout = nil
	cmd.Stderr = nil
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("failed to start mix pair server: %w", err)
	}

	for i := 0; i < 20; i++ {
		time.Sleep(500 * time.Millisecond)
		if resp, err := http.Get(fmt.Sprintf("http://%s:%s/health", bind, serverPort)); err == nil {
			resp.Body.Close()
			return nil
		}
	}
	return fmt.Errorf("server started but didn't become ready within 10s")
}

func openBrowser(url string) {
	browser := exec.Command("open", url)
	browser.Start()
}

// --- browse: interactive session picker ---

type session struct {
	ID       string `json:"id"`
	Agent    string `json:"agent"`
	URL      string `json:"url"`
	RootPath string `json:"root_path"`
	Server   string // populated by list/browse, not from JSON
}

type browseModel struct {
	sessions []session
	cursor   int
	action   string // "join" or "stop"
	quitting bool
	err      error
}

func (m browseModel) Init() tea.Cmd { return nil }

func (m browseModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "q", "esc", "ctrl+c":
			m.quitting = true
			return m, tea.Quit
		case "up", "k":
			if m.cursor > 0 {
				m.cursor--
			}
		case "down", "j":
			if m.cursor < len(m.sessions)-1 {
				m.cursor++
			}
		case "enter":
			m.action = "join"
			return m, tea.Quit
		case "backspace", "delete", "d":
			m.action = "stop"
			return m, tea.Quit
		}
	}
	return m, nil
}

func (m browseModel) View() string {
	if m.err != nil {
		return fmt.Sprintf("Error: %v\n", m.err)
	}

	if len(m.sessions) == 0 {
		return "No active sessions.\n"
	}

	var b strings.Builder
	b.WriteString("Sessions:\n\n")

	for i, s := range m.sessions {
		cursor := "  "
		if m.cursor == i {
			cursor = "▸ "
		}
		fmt.Fprintf(&b, "%s%s  %s  %s\n", cursor, s.Agent, s.ID, s.Server)
	}

	if m.cursor < len(m.sessions) {
		s := m.sessions[m.cursor]
		b.WriteString("\n")
		b.WriteString(strings.Repeat("─", 40))
		fmt.Fprintf(&b, "\nID:     %s\n", s.ID)
		fmt.Fprintf(&b, "Server: %s\n", s.Server)
		fmt.Fprintf(&b, "URL:    %s\n", s.URL)
	}

	b.WriteString("\n")
	b.WriteString(strings.Repeat("─", 40))
	b.WriteString("\n↑/↓ navigate  |  enter: join  |  d: stop  |  q: quit\n")

	return b.String()
}

func browse() {
	allSessions := fetchAllSessions()

	if len(allSessions) == 0 {
		fmt.Println("No active sessions.")
		return
	}

	m := browseModel{sessions: allSessions}
	p := tea.NewProgram(m, tea.WithoutSignalHandler())
	final, err := p.Run()
	if err != nil {
		fmt.Fprintf(os.Stderr, "TUI error: %v\n", err)
		os.Exit(1)
	}

	fm := final.(browseModel)
	if fm.quitting || fm.action == "" {
		return
	}

	sel := fm.sessions[fm.cursor]

	switch fm.action {
	case "join":
		joinSession(sel)
	case "stop":
		stopSession(sel)
	}
}

func printUsage() {
	fmt.Println(`Usage:
  pair <agent>            Start any coding agent locally
  pair connect <host>      Set remote server
  pair remote <agent>      Start agent on the remote server
  pair list                List sessions (local + remote)
  pair browse              Interactive session picker
  pair join <name>         Reconnect (partial match OK)
  pair stop <name>         Stop a session`)
}
