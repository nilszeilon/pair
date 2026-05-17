# pair

Give every agent session a browser-accessible terminal. Open it on your phone,
tablet, or another computer — all seeing the same screen.

Works with **pi**, **Claude Code**, **Codex**, or any terminal-based agent.

## What it does

Pair runs its own tmux server and exposes every session as a web terminal via
[ttyd](https://github.com/tsl0922/ttyd). Sessions are locked down (no splits,
no status bar) and auto-restart on crash.

```
  pair pi                    ← create and attach
       │
       ▼
  tmux -L pair session       ← pair's own socket, invisible to your tmux
       │
       ▼  auto-discovered
  Pair.HTTPServer (:4242)    ← dashboard + REST API
       │
       ▼
  ttyd :43XX                 ← browser terminal for your phone
```

## Quick start

```bash
# Prerequisites
brew install elixir tmux ttyd    # macOS
apt install tmux ttyd            # Linux (+ install Elixir 1.14+)

# Install
git clone https://github.com/nilszeilon/pair.git
cd pair
./install.sh

# Start
mix pair server
```

In another terminal:

```bash
pair pi                    # pi in current directory
pair claude                # claude in current directory
pair pi myproject          # named session "myproject"
```

Open `http://localhost:4242` — all sessions appear in the dashboard. Open any
ttyd URL on your phone. Same session, live.

## Usage

```bash
pair                  # pi in cwd (default)
pair claude           # any agent in cwd
pair pi myproject     # named session "myproject"
pair "pi --model gpt" # agent with arguments (quote it)
```

Sessions are locked down: no `C-b` prefix, no splits, no status bar. The
terminal is clean and single-purpose. Agent crashes (non-zero exit) trigger
an automatic restart. Clean exits (Ctrl+D, `exit`) stop the session.

**Under the hood:** `pair` is a thin wrapper around `tmux -L pair`. You can
always use tmux directly:

```bash
tmux -L pair ls                    # list pair sessions
tmux -L pair kill-session -t name  # stop one
```

## API

```
GET    /                       HTML dashboard (browsers) / JSON (API clients)
GET    /sessions               JSON session list
POST   /sessions               { root_path, agent }
GET    /session/:id            session state
DELETE /session/:id            stop session
GET    /health                 "ok"
```

## Running on a remote server

```bash
BIND=0.0.0.0 mix pair server
```

Open `http://<server-ip>:4242` from any device.

## Works with Tailscale

If Tailscale is running, the server binds to your Tailscale IP automatically
— no `BIND` needed. Open the URL on any device on your tailnet.

## Architecture

```
Pair.Application
  ├─ Registry            session lookup by ID
  ├─ DynamicSupervisor   session lifecycle
  ├─ SessionScanner      auto-discovers sessions on tmux -L pair
  └─ Bandit (:4242)
       └─ Pair.HTTPServer
            └─ Pair.SessionServer (one per session)
                 ├─ tmux -L pair session
                 ├─ remain-on-exit / prefix None / status off
                 ├─ ttyd on port 4300–4399
                 └─ health check every 10s → crash recovery
```

## Security

Designed for personal use on trusted networks:

- Binds to Tailscale IP by default, never `0.0.0.0` — cafe wifi can't see it
- Tailscale encrypts traffic end-to-end
- **No authentication** — anyone on your tailnet can access sessions
  (shared token auth planned)
