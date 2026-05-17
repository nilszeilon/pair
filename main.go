package main

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

//go:embed dashboard.html
var dashboardHTML string

//go:embed index.html
var indexHTML string

// ── Session ──────────────────────────────────────────────────────────

type Session struct {
	ID          string    `json:"id"`
	Agent       string    `json:"agent"`
	RootPath    string    `json:"root_path"`
	TmuxSession string    `json:"tmux_session"`
	URL         string    `json:"url"`
	PiAlive     bool      `json:"pi_alive"`
	Adopted     bool      `json:"adopted"`
	StartedAt   string    `json:"started_at"`

	ttydPort int
	cancel   chan struct{}
}

// ── Server ───────────────────────────────────────────────────────────

type Server struct {
	mu       sync.RWMutex
	sessions map[string]*Session
	bind     string
	port     int
	counter  atomic.Int64
}

func (s *Server) nextID() int64 {
	return s.counter.Add(1)
}

func (s *Server) listSessions() []Session {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var list []Session
	for _, sess := range s.sessions {
		list = append(list, *sess)
	}
	if list == nil {
		list = []Session{}
	}
	return list
}

// ── HTTP handlers ────────────────────────────────────────────────────

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Write([]byte("ok"))
}

func (s *Server) handleDashboard(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html")
	w.Write([]byte(dashboardHTML))
}

func (s *Server) handleSessions(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case "GET":
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(s.listSessions())

	case "POST":
		var body struct {
			RootPath string `json:"root_path"`
			Agent    string `json:"agent"`
			Name     string `json:"name"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			body.RootPath = ""
			body.Agent = "pi"
		}
		if body.Agent == "" {
			body.Agent = "pi"
		}
		if body.RootPath == "" {
			body.RootPath, _ = os.Getwd()
		} else {
			body.RootPath = resolvePath(body.RootPath)
		}
		if body.Name == "" {
			agentName := strings.Fields(body.Agent)[0]
			body.Name = fmt.Sprintf("%s-%d", agentName, s.nextID())
		}

		id := body.Name
		sess, err := s.startSession(id, body.RootPath, body.Agent, false)
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(201)
		json.NewEncoder(w).Encode(map[string]interface{}{
			"status": "started",
			"id":           sess.ID,
			"agent":        sess.Agent,
			"root_path":    sess.RootPath,
			"tmux_session": sess.TmuxSession,
			"url":          sess.URL,
			"pi_alive":     sess.PiAlive,
			"adopted":      sess.Adopted,
			"started_at":   sess.StartedAt,
		})
	}
}

func (s *Server) handleSession(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/session/")
	if id == "" {
		http.Error(w, "missing id", 400)
		return
	}

	switch r.Method {
	case "GET":
		s.mu.RLock()
		sess, ok := s.sessions[id]
		s.mu.RUnlock()
		if !ok {
			http.Error(w, "not found", 404)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(sess)

	case "DELETE":
		s.stopSession(id)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{
			"status":     "stopped",
			"session_id": id,
		})
	}
}

func (s *Server) mux() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", s.handleHealth)
	mux.HandleFunc("/sessions", s.handleSessions)
	mux.HandleFunc("/session/", s.handleSession)
	mux.HandleFunc("/", s.handleDashboard)
	return mux
}

// ── Session lifecycle ────────────────────────────────────────────────

func (s *Server) startSession(id, rootPath, agent string, adopted bool) (*Session, error) {
	tmuxName := id
	port := allocatePort(id)

	if !adopted {
		os.MkdirAll(rootPath, 0755)
		cmd := fmt.Sprintf("cd %s && exec %s", escapeShell(rootPath), agent)
		run("tmux", "-L", "pair", "new-session", "-d", "-s", tmuxName, "sh", "-c", cmd)
	}

	// Lock down
	run("tmux", "-L", "pair", "set-option", "-t", tmuxName, "prefix", "None")
	run("tmux", "-L", "pair", "set-option", "-t", tmuxName, "status", "off")

	// Start ttyd
	startTTYD(tmuxName, port, s.bind)

	// Wait briefly for ttyd to start
	time.Sleep(500 * time.Millisecond)

	sess := &Session{
		ID:          id,
		Agent:       agent,
		RootPath:    rootPath,
		TmuxSession: tmuxName,
		URL:         fmt.Sprintf("http://%s:%d", s.bind, port),
		PiAlive:     true,
		Adopted:     adopted,
		StartedAt:   time.Now().UTC().Format(time.RFC3339),
		ttydPort:    port,
		cancel:      make(chan struct{}),
	}

	s.mu.Lock()
	s.sessions[id] = sess
	s.mu.Unlock()

	// Start health check
	go s.healthCheck(sess)

	if adopted {
		log.Printf("Adopted session %s (%s)", id, agent)
	} else {
		log.Printf("Started session %s (%s)", id, agent)
	}

	return sess, nil
}

func (s *Server) stopSession(id string) {
	s.mu.Lock()
	sess, ok := s.sessions[id]
	if ok {
		delete(s.sessions, id)
		close(sess.cancel)
	}
	s.mu.Unlock()

	if sess != nil {
		run("tmux", "-L", "pair", "kill-session", "-t", sess.TmuxSession)
		time.Sleep(200 * time.Millisecond)
		run("pkill", "-f", fmt.Sprintf("ttyd.*%d", sess.ttydPort))
		log.Printf("Stopped session %s", id)
	}
}

func (s *Server) healthCheck(sess *Session) {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-sess.cancel:
			return
		case <-ticker.C:
			if !paneAlive(sess.TmuxSession) {
				log.Printf("Agent exited in %s, stopping", sess.ID)
				s.stopSession(sess.ID)
				return
			}
		}
	}
}

// ── Scanner ──────────────────────────────────────────────────────────

func (s *Server) scanner() {
	s.scanOnce()

	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()

	for range ticker.C {
		s.scanOnce()
	}
}

func (s *Server) scanOnce() {
	sessions := listPairSessions()
	s.mu.RLock()
	managed := make(map[string]bool)
	for id := range s.sessions {
		managed[id] = true
	}
	s.mu.RUnlock()

	for _, si := range sessions {
		if managed[si.name] {
			continue
		}
		if !paneAlive(si.name) {
			continue
		}
		s.startSession(si.name, si.path, si.command, true)
	}
}

type sessionInfo struct {
	name    string
	command string
	path    string
}

// ── Tmux helpers ─────────────────────────────────────────────────────

func run(name string, args ...string) {
	exec.Command(name, args...).Run()
}

func listPairSessions() []sessionInfo {
	out, err := exec.Command("tmux", "-L", "pair", "list-sessions",
		"-F", "#{session_name} #{pane_current_command} #{pane_current_path}").Output()
	if err != nil {
		return nil
	}

	var sessions []sessionInfo
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		parts := strings.SplitN(line, " ", 3)
		if len(parts) == 3 {
			sessions = append(sessions, sessionInfo{parts[0], parts[1], parts[2]})
		}
	}
	return sessions
}

func paneAlive(name string) bool {
	out, err := exec.Command("tmux", "-L", "pair", "list-panes",
		"-t", name, "-F", "#{pane_dead} #{pane_pid}").Output()
	if err != nil {
		return false
	}
	parts := strings.SplitN(strings.TrimSpace(string(out)), " ", 2)
	if len(parts) < 2 || parts[0] == "1" || parts[1] == "" || parts[1] == "0" {
		return false
	}
	pid, _ := strconv.Atoi(parts[1])
	if pid == 0 {
		return false
	}
	// Check if process exists
	return syscall.Kill(pid, 0) == nil
}

func startTTYD(sessionName string, port int, bind string) {
	// Kill any existing ttyd on this port
	run("pkill", "-f", fmt.Sprintf("ttyd.*%d", port))

	// Get absolute path to index.html (embedded, so write a temp copy)
	indexPath := writeTempIndex()

	cmd := fmt.Sprintf("ttyd -p %d -i %s --writable --index %s tmux -L pair attach -t %s",
		port, bind, indexPath, sessionName)
	exec.Command("sh", "-c", cmd+" > /dev/null 2>&1 &").Run()
}

var indexOnce sync.Once
var indexTempPath string

func writeTempIndex() string {
	indexOnce.Do(func() {
		f, err := os.CreateTemp("", "pair-index-*.html")
		if err == nil {
			f.WriteString(indexHTML)
			f.Close()
			indexTempPath = f.Name()
		}
	})
	if indexTempPath == "" {
		return "/dev/null"
	}
	return indexTempPath
}

func allocatePort(name string) int {
	h := fnv.New32a()
	h.Write([]byte(name))
	return 4300 + int(h.Sum32()%100)
}

// ── Helpers ──────────────────────────────────────────────────────────

func resolvePath(path string) string {
	home, _ := os.UserHomeDir()
	switch {
	case path == "~":
		return home
	case strings.HasPrefix(path, "~/"):
		return home + path[1:]
	case strings.HasPrefix(path, "/"):
		return path
	default:
		return filepath.Join(home, path)
	}
}

func escapeShell(s string) string {
	return strings.ReplaceAll(s, "'", "'\\''")
}

func tailscaleIP() string {
	out, err := exec.Command("tailscale", "ip", "-4").Output()
	if err != nil {
		return ""
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(lines) > 0 {
		return strings.TrimSpace(lines[len(lines)-1])
	}
	return ""
}

func serverAddr() (string, int) {
	bind := "127.0.0.1"
	if h := os.Getenv("PAIR_HOST"); h != "" {
		bind = h
	}
	port := 4242
	if p := os.Getenv("PAIR_PORT"); p != "" {
		if v, err := strconv.Atoi(p); err == nil {
			port = v
		}
	}
	return bind, port
}

func healthCheck(addr string) bool {
	resp, err := http.Get(addr)
	if err != nil {
		return false
	}
	resp.Body.Close()
	return resp.StatusCode == 200
}

func findServer() string {
	bind, port := serverAddr()

	// Try the configured address first
	addr := fmt.Sprintf("http://%s:%d/health", bind, port)
	if healthCheck(addr) {
		return fmt.Sprintf("http://%s:%d", bind, port)
	}

	// If it's localhost, also try Tailscale IP
	if bind == "127.0.0.1" {
		if ip := tailscaleIP(); ip != "" {
			addr = fmt.Sprintf("http://%s:%d/health", ip, port)
			if healthCheck(addr) {
				return fmt.Sprintf("http://%s:%d", ip, port)
			}
		}
	} else {
		// If it's a remote host, also try localhost
		addr = fmt.Sprintf("http://127.0.0.1:%d/health", port)
		if healthCheck(addr) {
			return fmt.Sprintf("http://127.0.0.1:%d", port)
		}
	}

	return ""
}

func ensureServer() {
	if base := findServer(); base != "" {
		return
	}

	// Start server in background
	exe, _ := os.Executable()
	cmd := exec.Command(exe, "server")
	cmd.Env = os.Environ()
	cmd.Start()

	// Wait for it to be ready
	bind, port := serverAddr()
	for i := 0; i < 20; i++ {
		time.Sleep(300 * time.Millisecond)
		addr := fmt.Sprintf("http://%s:%d/health", bind, port)
		if healthCheck(addr) {
			fmt.Printf("Pair server started → http://%s:%d\n", bind, port)
			return
		}
		// Also try Tailscale IP
		if ip := tailscaleIP(); ip != "" && bind != ip {
			addr = fmt.Sprintf("http://%s:%d/health", ip, port)
			if healthCheck(addr) {
				fmt.Printf("Pair server started → http://%s:%d\n", ip, port)
				return
			}
		}
	}

	fmt.Fprintf(os.Stderr, "Server not running. Start it with: pair server\n")
	os.Exit(1)
}

// ── CLI ──────────────────────────────────────────────────────────────

func printUsage() {
	fmt.Println(`Usage:
  pair server              Start the orchestrator
  pair <agent>             Start an agent session (default: pi)
  pair <agent> <name>      Named session
  pair "agent --args"      Agent with arguments`)
}

func cliSession(args []string) {
	agent := "pi"
	name := ""
	if len(args) > 0 {
		agent = args[0]
	}
	if len(args) > 1 {
		name = args[1]
	}

	dir, _ := os.Getwd()
	ensureServer()

	base := findServer()
	if base == "" {
		fmt.Fprintf(os.Stderr, "Server not running. Start it with: pair server\n")
		os.Exit(1)
	}

	// Create session via API — server handles tmux + lockdown + ttyd immediately
	body, _ := json.Marshal(map[string]string{
		"root_path": dir,
		"agent":     agent,
		"name":      name,
	})
	resp, err := http.Post(
		base+"/sessions",
		"application/json",
		bytes.NewReader(body),
	)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create session: %v\n", err)
		os.Exit(1)
	}
	defer resp.Body.Close()

	var result struct {
		ID string `json:"id"`
	}
	json.NewDecoder(resp.Body).Decode(&result)
	if result.ID == "" {
		fmt.Fprintf(os.Stderr, "Server returned no session ID\n")
		os.Exit(1)
	}

	// Attach to the session
	attachCmd := exec.Command("tmux", "-L", "pair", "attach", "-t", result.ID)
	attachCmd.Stdin = os.Stdin
	attachCmd.Stdout = os.Stdout
	attachCmd.Stderr = os.Stderr

	if os.Getenv("TMUX") != "" {
		syscall.Exec(attachCmd.Path, []string{"tmux", "-L", "pair", "attach", "-t", result.ID}, os.Environ())
	} else {
		attachCmd.Run()
	}
}

func cliServer() {
	bind := os.Getenv("BIND")
	if bind == "" {
		if ip := tailscaleIP(); ip != "" {
			bind = ip
		} else {
			bind = "127.0.0.1"
		}
	}
	port := 4242
	if p := os.Getenv("PAIR_PORT"); p != "" {
		if v, err := strconv.Atoi(p); err == nil {
			port = v
		}
	}

	// Start the pair tmux server
	exec.Command("tmux", "-L", "pair", "start-server").Run()

	srv := &Server{
		sessions: make(map[string]*Session),
		bind:     bind,
		port:     port,
	}

	// Start scanner
	go srv.scanner()

	addr := fmt.Sprintf("%s:%d", bind, port)
	fmt.Printf("🧠 Pair orchestrator → http://%s\n", addr)
	fmt.Printf("   Dashboard:  http://%s:%d\n", bind, port)
	fmt.Printf("   Sessions:   pair pi\n")

	log.Fatal(http.ListenAndServe(addr, srv.mux()))
}

func main() {
	if len(os.Args) < 2 || os.Args[1] == "help" || os.Args[1] == "--help" {
		printUsage()
		return
	}

	switch os.Args[1] {
	case "server":
		cliServer()
	default:
		cliSession(os.Args[1:])
	}
}
