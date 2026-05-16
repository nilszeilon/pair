# pair

Run a coding agent in a session that stays alive when you disconnect.
Share it with your phone, tablet, or another computer — all seeing the same screen.

Works with **pi**, **Claude Code**, **Codex**, or any terminal-based coding agent.

## What it does

Pair is a tiny Elixir server that wraps each agent session in a tmux window,
served over the web via ttyd. Sessions survive disconnects, and crashed agents
are restarted automatically.

```
 pair pi ──POST──►  Pair.HTTPServer (:4242)
                         │
                    GenServer per session
                         │
                    ├─► tmux -d "pair-<id>"  ← agent runs here
                    └─► ttyd :43XX           ← browser access
```

## Quick start

```bash
# Prerequisites
brew install elixir tmux ttyd    # macOS
apt install tmux ttyd            # Linux (+ install Elixir separately)

# Install
git clone https://github.com/nilszeilon/pair.git
cd pair
./install.sh

# Start the server
cd pair && mix pair server
```

Open `http://localhost:4242` in a browser — start a session, open the ttyd URL
on your phone. Same session, live.

## API

```
POST   /sessions              { root_path, agent, env, host }
GET    /session/:id            session state
DELETE /session/:id            stop session
GET    /                       HTML browse page (browsers) / JSON (API clients)
GET    /sessions               JSON session list
GET    /health                 "ok"
```

Start a session with curl:

```bash
curl -X POST http://localhost:4242/sessions \
  -H "Content-Type: application/json" \
  -d '{"root_path": "~", "agent": "pi"}'
```

## Running on a remote server

```bash
BIND=0.0.0.0 mix pair server
```

Then open `http://<server-ip>:4242` from your phone or laptop.

## Works with Tailscale

If Tailscale is running, the server binds to your Tailscale IP automatically.
Open the URL on any device on your tailnet — no config needed.
Falls back to localhost if Tailscale isn't running.

## Architecture

```
Pair.Application
  ├─ Registry (session lookup)
  ├─ DynamicSupervisor (session lifecycle)
  └─ Bandit (REST API :4242)
       └─ Pair.HTTPServer
            └─ Pair.SessionServer (GenServer per session)
                 ├─ tmux new-session -d -s pair-<id>
                 ├─ ttyd -p 43XX tmux attach -t pair-<id>
                 └─ health check every 10s → auto-restart
```

## Security

Designed for personal use on trusted networks:

- Binds to Tailscale IP by default, never `0.0.0.0` — cafe wifi can't see it
- Tailscale encrypts traffic end-to-end between devices
- **No authentication** — anyone on your tailnet can access sessions. Planned: shared token auth.
