# pair

Give every agent session a browser-accessible terminal. Open it on your phone,
tablet, or another computer — all seeing the same screen.

Works with **pi**, **Claude Code**, **Codex**, or any terminal-based agent.

## What it does

Pair is a tiny Elixir server (~1,000 lines) that runs its own `tmux` server
and exposes every session via [ttyd](https://github.com/tsl0922/ttyd). You
control what's shared by which tmux socket you use:

```
  tmux -L pair new -s myproject pi    ← shared via pair
  tmux new -s private                 ← invisible to pair
```

Pair auto-discovers sessions on its socket every 10 seconds, starts a ttyd
web terminal for each, and monitors health with automatic crash recovery.

## Quick start

```bash
# Prerequisites
brew install elixir tmux ttyd    # macOS
apt install tmux ttyd            # Linux (+ install Elixir 1.14+)

# Clone and build
git clone https://github.com/nilszeilon/pair.git
cd pair
./install.sh

# Start
cd pair && mix pair server
```

Open `http://localhost:4242` — any session you create on the pair socket appears
within 10 seconds.

## Usage

**From the terminal:**

```bash
tmux -L pair new-session -s myproject pi
```

That's it. Pair detects the session, starts ttyd, and shows it in the dashboard
at `http://localhost:4242`. Open the ttyd URL on your phone — same session, live.

Multi-pane? Go ahead — it's a regular tmux session. `C-b %` splits, `C-b o`
switches. All panes are visible via the ttyd URL.

**From the browser:** open `http://localhost:4242`, pick an agent and path,
click Start. The session is created on the pair socket.

**From curl:**

```bash
curl -X POST http://localhost:4242/sessions \
  -H "Content-Type: application/json" \
  -d '{"root_path": "~", "agent": "pi"}'
```

**Stop a session:**

```bash
tmux -L pair kill-session -t myproject
# or
curl -X DELETE http://localhost:4242/session/myproject
```

## API

```
GET    /                       HTML dashboard (browsers) / JSON (API clients)
GET    /sessions               JSON session list
POST   /sessions               { root_path, agent, env, host }
GET    /session/:id            session state
DELETE /session/:id            stop session (keeps tmux alive if adopted)
GET    /health                 "ok"
```

## Running on a remote server

```bash
BIND=0.0.0.0 mix pair server
```

Open `http://<server-ip>:4242` from any device. Create sessions on the server
with `tmux -L pair new -s name pi`.

## Works with Tailscale

If Tailscale is running, the server binds to your Tailscale IP automatically
— no `BIND` needed. Open the URL on any device on your tailnet.

## Architecture

```
Pair.Application
  ├─ Registry            session lookup by ID
  ├─ DynamicSupervisor   session lifecycle
  ├─ SessionScanner      discovers sessions on tmux -L pair
  └─ Bandit (:4242)
       └─ Pair.HTTPServer
            └─ Pair.SessionServer (one per session)
                 ├─ tmux -L pair session (created or adopted)
                 ├─ ttyd on port 4300–4399
                 └─ health check every 10s → auto-restart crashed agents
```

## Security

Designed for personal use on trusted networks:

- Binds to Tailscale IP by default, never `0.0.0.0` — cafe wifi can't see it
- Tailscale encrypts traffic end-to-end
- **No authentication** — anyone on your tailnet can access sessions
  (shared token auth planned)
