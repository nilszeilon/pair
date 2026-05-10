package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"math/rand/v2"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
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
	default:
		// pair pi, pair claude, pair pi /path
		start(os.Args[1:])
	}
}

func start(args []string) {
	agent := args[0]
	var rootPath string
	
	host := serverHost()
	isRemote := host != "127.0.0.1"
	
	if isRemote {
		cwd, _ := os.Getwd()
		id := filepath.Base(cwd) + fmt.Sprintf("-%d", rand.IntN(999))
		rootPath = "/tmp/pair-sessions/" + id
	} else {
		if len(args) > 1 {
			rootPath = args[1]
		} else {
			rootPath, _ = os.Getwd()
		}
	}
	
	id := filepath.Base(rootPath) + fmt.Sprintf("-%d", rand.IntN(999))
	
	// Build request
	body := map[string]interface{}{
		"root_path": rootPath,
		"env":       map[string]string{},
		"agent":     agent,
		"host":      host,
	}
	bodyJSON, _ := json.Marshal(body)
	
	url := fmt.Sprintf("http://%s:%s/session/%s/start", host, serverPort, id)
	
	resp, err := http.Post(url, "application/json", bytes.NewReader(bodyJSON))
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to reach server at %s:%s\n", host, serverPort)
		fmt.Fprintf(os.Stderr, "Is the orchestrator running? Run: pair server\n")
		os.Exit(1)
	}
	defer resp.Body.Close()
	
	var result map[string]interface{}
	respBody, _ := io.ReadAll(resp.Body)
	json.Unmarshal(respBody, &result)
	
	url2, _ := result["url"].(string)
	
	if !isRemote {
		// Local: tmux attach
		tmuxPath, _ := exec.LookPath("tmux")
		syscall.Exec(tmuxPath, []string{"tmux", "attach", "-t", "pair-" + id}, os.Environ())
		return
	}
	
	// Remote: HTTP success, now exec SSH
	fmt.Printf("Connecting to %s ...\n", host)
	
	// Find SSH key if available
	home, _ := os.UserHomeDir()
	keyPath := filepath.Join(home, ".ssh/pair")
	sshArgs := []string{"ssh", "-tt", "-o", "StrictHostKeyChecking=no"}
	if _, err := os.Stat(keyPath); err == nil {
		sshArgs = append(sshArgs, "-i", keyPath)
	}
	
	dest := host
	if !strings.Contains(dest, "@") {
		dest = "root@" + dest
	}
	
	sshArgs = append(sshArgs, dest, "tmux", "attach", "-t", "pair-"+id)
	
	// Try SSH, fall back to browser
	fmt.Printf("  ssh -tt %s tmux attach -t pair-%s\n", dest, id)
	fmt.Printf("\nBrowser: %s\n", url2)
	
	sshPath, _ := exec.LookPath("ssh")
	if os.Getenv("PAIR_NO_EXEC") == "1" {
		// Debug mode: just print, don't exec
		openBrowser(url2)
		os.Exit(0)
	}
	
	// execve replaces this process with ssh — PTY preserved
	syscall.Exec(sshPath, sshArgs, os.Environ())
	
	// If we get here, exec failed
	fmt.Fprintf(os.Stderr, "\nSSH failed. Opening browser: %s\n", url2)
	openBrowser(url2)
}

func join(name string) {
	host := serverHost()
	
	resp, err := http.Get(fmt.Sprintf("http://%s:%s/session/%s", host, serverPort, name))
	if err != nil {
		fmt.Fprintf(os.Stderr, "Session '%s' not found.\n", name)
		os.Exit(1)
	}
	defer resp.Body.Close()
	
	var state map[string]interface{}
	json.NewDecoder(resp.Body).Decode(&state)
	url2, _ := state["url"].(string)
	
	// Build SSH args
	home, _ := os.UserHomeDir()
	keyPath := filepath.Join(home, ".ssh/pair")
	sshArgs := []string{"ssh", "-tt", "-o", "StrictHostKeyChecking=no"}
	if _, err := os.Stat(keyPath); err == nil {
		sshArgs = append(sshArgs, "-i", keyPath)
	}
	
	dest := host
	if !strings.Contains(dest, "@") {
		dest = "root@" + dest
	}
	
	sshArgs = append(sshArgs, dest, "tmux", "attach", "-t", "pair-"+name)
	
	fmt.Printf("Connecting to %s ...\n", host)
	fmt.Printf("  ssh -tt %s tmux attach -t pair-%s\n", dest, name)
	fmt.Printf("\nBrowser: %s\n", url2)
	
	sshPath, _ := exec.LookPath("ssh")
	syscall.Exec(sshPath, sshArgs, os.Environ())
	
	// Exec failed
	fmt.Fprintf(os.Stderr, "SSH failed. Opening browser: %s\n", url2)
	openBrowser(url2)
}

func list() {
	host := serverHost()
	resp, err := http.Get(fmt.Sprintf("http://%s:%s/", host, serverPort))
	if err != nil {
		fmt.Fprintf(os.Stderr, "Could not reach orchestrator at %s\n", host)
		os.Exit(1)
	}
	defer resp.Body.Close()
	
	var sessions []map[string]interface{}
	json.NewDecoder(resp.Body).Decode(&sessions)
	
	if len(sessions) == 0 {
		fmt.Println("No active sessions.")
		return
	}
	
	fmt.Println("Active sessions:")
	for _, s := range sessions {
		fmt.Printf("  %s\n", s["id"])
		fmt.Printf("    Agent:  %s\n", s["agent"])
		fmt.Printf("    URL:    %s\n", s["url"])
		fmt.Printf("    Path:   %s\n", s["root_path"])
		fmt.Println()
	}
}

func stop(name string) {
	host := serverHost()
	req, _ := http.NewRequest("DELETE", fmt.Sprintf("http://%s:%s/session/%s", host, serverPort, name), nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
	defer resp.Body.Close()
	fmt.Printf("Stopped session '%s'\n", name)
}

func connect(host string) {
	home, _ := os.UserHomeDir()
	configDir := filepath.Join(home, ".pair")
	os.MkdirAll(configDir, 0700)
	os.WriteFile(filepath.Join(configDir, "host"), []byte(host+"\n"), 0600)
	fmt.Printf("Server set to %s\n", host)
}

func serverHost() string {
	if h := os.Getenv("PAIR_HOST"); h != "" {
		return h
	}
	home, _ := os.UserHomeDir()
	data, err := os.ReadFile(filepath.Join(home, ".pair", "host"))
	if err == nil {
		return strings.TrimSpace(string(data))
	}
	return "127.0.0.1"
}

func openBrowser(url string) {
	browser := exec.Command("open", url)
	browser.Start()
}

func printUsage() {
	fmt.Println(`Usage:
  pair server              Start orchestrator daemon (Elixir)
  pair connect <host>      Set default server
  pair pi                  Start pi in current dir
  pair claude /path        Start Claude in /path
  pair list                List sessions
  pair join <name>         Join session
  pair stop <name>         Stop session`)
}
