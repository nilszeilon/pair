# pair

Run a coding agent in a terminal session that stays alive when you disconnect.
Open it on your phone, tablet, or another computer — all seeing the same screen.

Works with **pi**, **Claude Code**, **Codex**, or any terminal-based agent.

## How it works

Pair runs its own tmux server and exposes every session as a web terminal via
[ttyd](https://github.com/tsl0922/ttyd). It binds to your
[Tailscale](https://tailscale.com) IP automatically, so any device on your
tailnet can open the session URL.

Single Go binary. Zero dependencies beyond the standard library.

## Install

```bash
# macOS
brew install go tmux ttyd
brew install --cask tailscale && tailscale up

# Ubuntu
sudo apt install -y golang tmux ttyd
curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up
```

Then:

```bash
go install github.com/nilszeilon/pair@latest
```

The binary lands in `~/go/bin/pair`. Make sure `~/go/bin` is on your `PATH`
(standard Go setup — add `export PATH=$HOME/go/bin:$PATH` to `~/.bashrc`).

## Usage

```bash
pair pi                  # auto-starts server, creates session, attaches you
```

That's it. The server auto-starts in the background on first use.
Open the dashboard URL (it uses your Tailscale IP) on your phone.

```bash
pair claude              # any agent
pair pi myproject        # named session
pair "pi --model gpt"    # agent with arguments (quote it)
pair server &            # start server explicitly in background
pair browse              # list sessions and pick one to attach to
pair browse myproject    # attach to a named session directly
```

Sessions are locked down — no `C-b` prefix, no splits, no status bar.
When the agent exits, the session is fully cleaned up and you return
to your shell or tmux pane.

## Under the hood

`pair` wraps `tmux -L pair` — its own isolated tmux server. Your regular
tmux sessions are untouched.

```bash
tmux -L pair ls                    # list pair sessions
tmux -L pair kill-session -t name  # stop one manually
```

## Architecture

```
Server (568 lines of Go)
  ├─ in-memory session registry
  ├─ scanner goroutine     discovers sessions on tmux -L pair
  └─ HTTP (:4242)
       ├─ GET  /             dashboard
       ├─ GET  /sessions     JSON session list
       ├─ POST /sessions     create session → returns ID
       ├─ GET  /session/:id  session state
       └─ DELETE /session/:id stop session

Per session:
  ├─ tmux -L pair session  (prefix None, status off)
  ├─ ttyd on port 4300–4399
  └─ health check every 10s → removes dead sessions
```

## Running without Tailscale

```bash
BIND=0.0.0.0 pair server       # local network
BIND=127.0.0.1 pair server     # localhost only
```

## Security

Pair binds to your Tailscale IP by default — only devices on your tailnet
can connect. Traffic is encrypted end-to-end by Tailscale. No authentication
on the API or ttyd ports. Treat your tailnet as the security boundary.
