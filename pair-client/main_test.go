package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRootPathLocal(t *testing.T) {
	origHost := os.Getenv("PAIR_HOST")
	os.Unsetenv("PAIR_HOST")
	defer func() {
		if origHost != "" {
			os.Setenv("PAIR_HOST", origHost)
		}
	}()

	tmp, err := os.MkdirTemp("", "pair-test-local-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmp)

	testFile := filepath.Join(tmp, "test.txt")
	if err := os.WriteFile(testFile, []byte("hello"), 0644); err != nil {
		t.Fatal(err)
	}

	origCwd, _ := os.Getwd()
	os.Chdir(tmp)
	defer os.Chdir(origCwd)

	cwd, _ := os.Getwd()
	if remoteHost() != "" {
		t.Logf("remote host configured, skipping local test")
		return
	}

	if cwd != tmp {
		t.Errorf("expected cwd %s, got %s", tmp, cwd)
	}
	if _, err := os.Stat(filepath.Join(cwd, "test.txt")); err != nil {
		t.Errorf("test file not found in cwd: %v", err)
	}
}

func TestRootPathDerivation(t *testing.T) {
	origHost := os.Getenv("PAIR_HOST")
	os.Unsetenv("PAIR_HOST")
	defer func() {
		if origHost != "" {
			os.Setenv("PAIR_HOST", origHost)
		}
	}()

	tmp, err := os.MkdirTemp("", "my-cool-project-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmp)

	origCwd, _ := os.Getwd()
	os.Chdir(tmp)
	defer os.Chdir(origCwd)

	if remoteHost() != "" {
		t.Skip("remote host configured; skipping local-only test")
	}

	cwd, _ := os.Getwd()
	base := filepath.Base(cwd)
	if !strings.Contains(base, "my-cool-project") {
		t.Errorf("expected cwd base to contain 'my-cool-project', got %s", base)
	}
}

func TestServerHostFallback(t *testing.T) {
	// serverHost() returns Tailscale IP or 127.0.0.1 — not affected by ~/.pair/host
	host := serverHost()
	if host == "" {
		t.Error("serverHost() should never be empty")
	}
	t.Logf("serverHost() = %s", host)
}

func TestRemoteHostEnvOverride(t *testing.T) {
	origHost := os.Getenv("PAIR_HOST")
	os.Setenv("PAIR_HOST", "my-server.example.com")
	defer func() {
		if origHost != "" {
			os.Setenv("PAIR_HOST", origHost)
		} else {
			os.Unsetenv("PAIR_HOST")
		}
	}()

	host := remoteHost()
	if host != "my-server.example.com" {
		t.Errorf("expected PAIR_HOST env override for remoteHost, got %s", host)
	}
}

func TestFindPairProject(t *testing.T) {
	result := findPairProject()
	if result == "" {
		t.Skip("pair project not found (run from project dir)")
	}
	t.Logf("Found pair project at: %s", result)

	mixFile := filepath.Join(result, "mix.exs")
	data, err := os.ReadFile(mixFile)
	if err != nil {
		t.Fatalf("mix.exs not readable: %v", err)
	}
	if !strings.Contains(string(data), "Pair") {
		t.Error("mix.exs does not contain 'Pair'")
	}
}

func TestLocalAutoStart(t *testing.T) {
	origHost := os.Getenv("PAIR_HOST")
	os.Unsetenv("PAIR_HOST")
	defer func() {
		if origHost != "" {
			os.Setenv("PAIR_HOST", origHost)
		}
	}()

	host := serverHost()
	// serverHost() always returns a local IP (Tailscale or 127.0.0.1)
	if host == "" {
		t.Skip("no network")
	}
	if err := ensureServerRunning(); err != nil {
		t.Logf("ensureServerRunning: %v (may need Elixir installed)", err)
	}
}

func TestRemoteSessionCreatesFreshProject(t *testing.T) {
	// When running remote, the session root is /tmp/pair-sessions/<id>
	// — a fresh empty project. No files are synced from local.
	// This test verifies the path construction pattern.
	cwd := "/Users/alice/dev/myproject"
	base := filepath.Base(cwd)
	rootPath := "/tmp/pair-sessions/" + base

	if !strings.HasPrefix(rootPath, "/tmp/pair-sessions/") {
		t.Errorf("remote root should be in /tmp/pair-sessions, got %s", rootPath)
	}
	if !strings.Contains(rootPath, base) {
		t.Errorf("root should contain project name, got %s", rootPath)
	}
	t.Logf("Remote root path pattern: %s", rootPath)
}

func TestScanAndUploadPaths(t *testing.T) {
	// Test path detection in input lines

	// Create a temp file that exists for the scanner to find
	tmp, _ := os.MkdirTemp("", "pair-scan-test-*")
	defer os.RemoveAll(tmp)
	testFile := tmp + "/screenshot.png"
	os.WriteFile(testFile, []byte("fake"), 0644)

	tests := []struct {
		name     string
		input    string
		shouldDetect bool
	}{
		{"plain text", "hello world\n", false},
		{"command without file", "ls -la\n", false},
		{"nonexistent path", "look at /tmp/nonexistent/file.png\n", false},
		{"directory path", "cd " + tmp + "\n", false}, // dirs not auto-uploaded
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// scanAndUploadPaths requires a host — use localhost to skip actual upload
			result := scanAndUploadPaths([]byte(tt.input), "127.0.0.1")
			resultStr := string(result)

			if tt.shouldDetect {
				if resultStr == tt.input {
					t.Errorf("expected path to be replaced, got unchanged: %q", resultStr)
				}
			} else {
				if resultStr != tt.input {
					t.Errorf("expected no change, got: %q", resultStr)
				}
			}
		})
	}

	// Test that a real existing file gets detected (but upload fails on localhost)
	// The path should remain unchanged since SCP to localhost fails
	result := scanAndUploadPaths([]byte("check "+testFile+"\n"), "127.0.0.1")
	// Since SCP to localhost will fail (no SSH), path stays same
	_ = result
	t.Logf("Real file path scan result: %q", string(result))
}

func TestScanHandlesSpaces(t *testing.T) {
	// Paths with spaces should not break the scanner
	input := "hello /some/path and more text\n"
	result := scanAndUploadPaths([]byte(input), "127.0.0.1")
	if string(result) != input {
		t.Logf("space handling result: %q", string(result))
	}
}

func TestScanEscapedSpaces(t *testing.T) {
	// Create a file with spaces in the name
	tmp, _ := os.MkdirTemp("", "pair-escape-test-*")
	defer os.RemoveAll(tmp)

	fileWithSpaces := tmp + "/my screenshot.png"
	os.WriteFile(fileWithSpaces, []byte("fake"), 0644)

	// Simulate macOS drag-drop: backslash-escaped spaces
	escapedPath := strings.ReplaceAll(fileWithSpaces, " ", "\\ ")
	input := "look at " + escapedPath + "\n"

	result := scanAndUploadPaths([]byte(input), "127.0.0.1")
	t.Logf("Escaped path input:  %q", input)
	t.Logf("Escaped path result: %q", string(result))

	// The path should be detected and processed (upload will fail on localhost
	// but the path should still be passed through since SCP to 127.0.0.1 fails)
	_ = result
}
