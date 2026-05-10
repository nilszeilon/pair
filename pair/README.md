# Pair

Fault-tolerant, shareable coding agent sessions. 596 lines of Elixir.

Start any CLI agent inside tmux, served via ttyd. Multiple devices share
the same session. Agent runs on the server, files sync instantly to your laptop.

## Quick start

```bash
# Prerequisites
mix deps.get
brew install tmux ttyd syncthing

# Server (always-on machine)
pair server

# Any terminal
pair pi
```

## Commands

```
pair server              Start orchestrator daemon
pair pi                  Start pi session in current dir
pair claude /path        Start Claude in /path
pair list                List all sessions
pair join <name>         Switch to session
pair stop <name>         Stop a session
```

## Ways to interact

| Method | Command |
|--------|---------|
| Browser | Open the printed URL (any device, phone, tablet) |
| Tmux | `pair join <name>` or `tmux switch-client -t pair-<name>` |
| Direct | `tmux attach -t pair-<name>` |

## File sync (Syncthing)

Agent runs on the server. Your local files stay in sync automatically:

```bash
# One-time setup on both machines
brew install syncthing
syncthing                           # starts daemon

# Open http://localhost:8384 on both machines
# Add the remote device, share the project folder
# Files sync within seconds, both directions
```

Now when you code locally, changes appear on the server instantly.
When the agent writes files, they appear on your laptop instantly.
No git, no polling — Syncthing handles it over an encrypted P2P connection.

## Credentials

```bash
KEY=sk-ant-... pair pi              # Explicit key
ANTHROPIC_API_KEY=... pair pi       # Env var (auto-detected)
```

Keys live in tmux process memory only — never on disk. Session dies → keys gone.

## Conversation persistence

Each session gets a dedicated conversation file.
If the agent crashes, the health checker restarts it within 10 seconds,
resuming the exact same conversation via `--session <file>`.

## Architecture

```
pair server
  └─ Bandit (REST API :4242)
       └─ GenServer per session
            ├─ tmux (keeps agent alive across disconnects)
            ├─ ttyd (terminal over HTTP, xterm.js)
            └─ health check + auto-restart every 10s
```

## Remote server

```bash
# On server (Tailscale for secure access)
BIND=0.0.0.0 pair server

# On laptop
pair pi --server 100.x.x.x
```

## Install globally

```bash
cp bin/pair /usr/local/bin/pair
# or: alias pair='mix pair'
```
