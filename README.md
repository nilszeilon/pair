# pair

Share a coding agent session from any device.

```
pair pi          # start pi on server, SSH into tmux session
pair join <name> # join existing session  
pair list        # list active sessions
pair stop <name> # stop a session
```

**Server** (Elixir): GenServer orchestrates tmux + ttyd. Fault-tolerant — sessions survive disconnects. Health checks auto-recover crashed agents.

**Client** (Go): single binary, `syscall.Exec` into SSH for native terminal PTY. No runtime, no VM.

## Install

### Server
```bash
cd pair
mix deps.get
mix pair server
```

### Client
```bash
cd pair-client
go build -ldflags="-s -w" -o /usr/local/bin/pair .
pair connect <your-server>
```

## Connect

- **Terminal:** `pair pi` — SSH with native PTY passthrough
- **Browser:** URL printed on start — ttyd + xterm.js
- **Phone:** same browser URL, readable 18px font

Both attach to the same tmux session — multiple devices, one agent.
