# pair

Run a coding agent in a tmux session that stays alive when you disconnect.
Open it on your phone, tablet, or another computer — all seeing the same screen.

Works with **pi**, **Claude Code**, **Codex**, or any terminal-based agent.

## What it does

Pair is a tiny Elixir server (~1,000 lines) that gives every agent session a
browser-accessible terminal via [ttyd](https://github.com/tsl0922/ttyd). Sessions
survive disconnects, crashed agents are restarted automatically, and existing
tmux sessions running known agents are auto-discovered.

```
  Any tmux session running pi/claude/codex/aider
                    │
                    ▼   auto-discovered every 10s
          Pair.HTTPServer (:4242)
                    │
             GenServer per session
                    │
             ├─► tmux session (created or adopted)
             └─► ttyd :43XX — browser terminal
```

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

Open `http://localhost:4242` — start a new session from the browser, or
any tmux session running `pi` will appear automatically within 10 seconds.

## Usage

**Start a session from the browser:** open `http://localhost:4242`, pick an
agent and path, click Start. The ttyd URL opens in a new tab — share it with
your phone.

**Auto-discovery:** start an agent in tmux however you normally would:

```bash
tmux new-session -s myproject pi
```

Pair detects it within 10 seconds and exposes it at a browser URL. No
configuration needed.

**From curl:**

```bash
curl -X POST http://localhost:4242/sessions \
  -H "Content-Type: application/json" \
  -d '{"root_path": "~", "agent": "pi"}'
```

**Detect custom agents:** set `PAIR_AGENTS` to a comma-separated list:

```bash
PAIR_AGENTS="pi,claude,aider,cursor-agent" mix pair server
```

## API

```
GET    /                       HTML dashboard (browsers) / JSON (API clients)
GET    /sessions               JSON session list
POST   /sessions               { root_path, agent, env, host }
GET    /session/:id            session state (includes adopted flag)
DELETE /session/:id            stop session (adopted: keeps tmux alive)
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
  ├─ SessionScanner      auto-discovers tmux sessions running agents
  └─ Bandit (:4242)
       └─ Pair.HTTPServer
            └─ Pair.SessionServer (one per session)
                 ├─ tmux session (created or adopted)
                 ├─ ttyd on port 4300–4399
                 └─ health check every 10s → auto-restart crashed agents
```

## Security

Designed for personal use on trusted networks:

- Binds to Tailscale IP by default, never `0.0.0.0` — cafe wifi can't see it
- Tailscale encrypts traffic end-to-end
- **No authentication** — anyone on your tailnet can access sessions
  (shared token auth planned)
