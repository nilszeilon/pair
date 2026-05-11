# pair

Run a coding agent in a session that stays alive when you disconnect.
Share it with your phone, tablet, or another computer — all seeing the same screen.

Works with **pi**, **Claude Code**, **Codex**, or any terminal-based coding agent.

## Architecture

Pair has two parts, both installed by `./install.sh`:

- **Server** (Elixir) — runs the agent inside tmux, serves browser access via ttyd
- **Client** (Go) — the `pair` command you type. Talks to a server (local or remote)

Your machine runs both — `pair pi` auto-starts a local server. You can also
run the server on a remote machine and connect from anywhere.

---

## Install

macOS:

```bash
brew install elixir tmux ttyd golang
```

Linux:

```bash
apt install elixir tmux ttyd golang
```

Optional: [Tailscale](https://tailscale.com/download) for phone access

```bash
git clone git@github.com:nilszeilon/pair.git
cd pair
./install.sh
source ~/.bashrc
```

HTTPS clone: `git clone https://github.com/nilszeilon/pair.git`  
zsh users: `source ~/.zshrc`

That's it. `./install.sh` builds the Go client, compiles the Elixir server,
and adds `pair` to your PATH.

No need to start the server manually — `pair pi` auto-starts it and binds
to your Tailscale IP automatically.

To run the server as a daemon on a remote machine:

```bash
cd pair/pair
mix pair server
```

Then from your laptop: `pair connect <server>` and `pair remote pi`.

---

## Usage

### Work locally, follow from your phone

```bash
pair pi
pair claude
pair aider --model gpt-4
```

Starts the server if needed, launches pi in your current directory.
Open the printed URL on your phone — same session, live.

`Ctrl+B d` to detach and leave the agent running. `Ctrl+B s` to switch between sessions.

### Work on a remote server, connect from anywhere

```bash
pair connect myserver.example.com
pair remote pi
```

Close the terminal to disconnect — the session keeps running.
Reconnect later with `pair browse` or `pair join <name>`.

Want existing code on the server? SSH in, run `pair pi` there, close the
window. From your laptop, `pair join <name>` attaches to the same session.

On the server:

```bash
ssh myserver
cd ~/projects/myapp
pair pi
```

On your laptop (with `pair connect` already set):

```bash
pair join myapp
```

### Managing sessions

```bash
pair list
pair browse
pair join <name>
pair stop <name>
```

---

## Works with Tailscale

If Tailscale is running, the local server binds to your Tailscale IP automatically.
Your phone on the same tailnet can open the browser URL. Devices on the local
network (cafe wifi) cannot — the server only listens on the Tailscale interface.

No configuration needed. Falls back to localhost if Tailscale isn't running.

## Dragging images

When connected to a remote session, the agent can't read files from your local
machine. Just drag an image into the terminal — pair detects the paste, uploads
the file to the server, and silently replaces the path. The agent sees
`/tmp/pair-uploads/screenshot.png` instead of your local path.



https://github.com/user-attachments/assets/48566ee3-4281-416c-abe8-62cc53ad24b9



---

## How it works

```
                    ┌───────── Server ──────────┐
pair pi ──POST──►   │  Pair.HTTPServer (:4242)  │
                    │    │                       │
                    │    ▼                       │
                    │  GenServer per session     │
                    │    │                       │
                    │    ├─► tmux -d "pair-<id>" │  ← agent runs here
                    │    └─► ttyd :43XX          │  ← browser access
                    └────────┬───────────────────┘
                             │
           ┌─────────────────┼─────────────────┐
           ▼                 ▼                  ▼
    SSH terminal       Browser (phone)    Another SSH
    (native PTY)       (xterm.js)        (native PTY)
```

- **tmux** — session persistence, multi-client, survives disconnects
- **ttyd** — terminal over WebSocket, no SSH needed on your phone
- **Health checks** — agent crashes → restarts with same conversation within 10s

## Security

Pair is designed for personal use on trusted networks. Know the risks:

**What protects you:**
- Local server binds to Tailscale IP, never `0.0.0.0` — cafe wifi can't see it
- Tailscale encrypts traffic end-to-end between your devices
- API keys stay on the server — pair doesn't forward credentials

**What doesn't:**
- **No authentication on ttyd** — anyone on your tailnet who knows the port gets a terminal session. If a tailnet device is compromised, so is your machine.
- **No authentication on the REST API** (:4242) — anyone on your tailnet can manage sessions.
- **Predictable ports** — ttyd ports are deterministic (`4300 + hash % 100`). Not a secret.

Planned: shared token auth for API and ttyd.
