# pair

Run a coding agent in a terminal session that stays alive when you disconnect.
Open it on your phone, tablet, or another computer — all seeing the same screen.

Works with **pi**, **Claude Code**, **Codex**, or any terminal-based agent.

## How it works

Pair runs its own tmux server and exposes every session as a web terminal via
[ttyd](https://github.com/tsl0922/ttyd). It binds to your
[Tailscale](https://tailscale.com) IP automatically, so any device on your
tailnet can open the session URL. No ports to forward, no `0.0.0.0` bind,
no cafe wifi exposure.

Single Go binary. Zero dependencies beyond the Go standard library.

```
  pair pi                    ← create and attach
       │
       ▼
  tmux -L pair session       ← pair's own tmux server
       │
       ▼  auto-discovered
  HTTP server (:4242)        ← dashboard + REST API
       │
       ▼
  ttyd :43XX                 ← browser terminal → open on any tailnet device
```

## Requirements

- **Go** 1.21+
- **tmux** — session persistence
- **ttyd** — terminal over WebSocket
- **Tailscale** — network access for your other devices

```bash
# macOS
brew install go tmux ttyd
brew install --cask tailscale && tailscale up

# Linux
apt install golang tmux ttyd
curl -fsSL https://tailscale.com/install.sh | sh && tailscale up
```

## Quick start

```bash
git clone https://github.com/nilszeilon/pair.git
cd pair
./install.sh
pair server
```

In another terminal:

```bash
pair pi                    # pi in cwd → auto-named "pi-1"
pair claude                # claude in cwd → "claude-1"
pair pi myproject          # named "myproject"
```

Open the dashboard URL printed by the server (it uses your Tailscale IP).
Tap any session's ttyd link on your phone — same session, live.

## Usage

```bash
pair                  # pi in cwd (default) → "pi-2"
pair claude           # any agent → "claude-1"
pair pi myproject     # custom name
pair "pi --model gpt" # agent with arguments (quote it)
```

Sessions are locked down: no `C-b` prefix, no splits, no status bar.
When the agent exits, the session is cleaned up completely. From inside
tmux, you return to your pane. From a regular terminal, you return to
your shell.

**Under the hood:** `pair` wraps `tmux -L pair`. You can use tmux directly:

```bash
tmux -L pair ls                    # list pair sessions
tmux -L pair kill-session -t name  # stop one
```

## Architecture

```
Server
  ├─ map[string]*Session   in-memory session registry
  ├─ scanner goroutine     discovers sessions on tmux -L pair (every 10s)
  └─ HTTP (:4242)
       ├─ GET  /             dashboard HTML
       ├─ GET  /sessions     JSON session list
       ├─ POST /sessions     create managed session
       ├─ GET  /session/:id  session state
       └─ DELETE /session/:id stop session

Per session:
  ├─ tmux -L pair session  (prefix None, status off)
  ├─ ttyd on port 4300–4399
  └─ health check goroutine (every 10s → remove dead sessions)
```

## API

```
GET    /                       dashboard HTML
GET    /sessions               JSON session list
POST   /sessions               { root_path, agent }
GET    /session/:id            session state
DELETE /session/:id            stop session
GET    /health                 "ok"
```

## Running without Tailscale

If Tailscale isn't running, the server falls back to `127.0.0.1`. To share on
a local network:

```bash
BIND=0.0.0.0 pair server
```

## Security

Pair binds to your Tailscale IP — only devices on your tailnet can connect.
Traffic is encrypted end-to-end by Tailscale. No authentication on the REST
API or ttyd ports — treat your tailnet as the security boundary.
