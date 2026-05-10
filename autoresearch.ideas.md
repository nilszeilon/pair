
## pair: programmatic SSH dead end

**Finding**: Erlang's process model cannot provide a real PTY to child processes spawned via `System.cmd` or `Port.open({:spawn, ...})`. Even with `:use_stdio`, the child gets the VM's stdio which is not a true PTY when running under `mix`.

- `System.cmd` → creates pipes, not PTYs → buffering, encoding, signal issues
- `Port.open({:spawn, cmd}, [:use_stdio, ...])` → shares VM stdio but mix doesn't connect it to a real TTY
- `:binary`/`:stream` port options create additional pipes that bypass the terminal

**What works**:
- Browser: ttyd has a real PTY → WebSocket → xterm.js (perfect rendering + interactivity)
- Manual SSH: user's terminal IS a real PTY → ssh -tt passes it through (perfect)

**Future approaches if terminal access needed**:
- Write a small native binary (Go/Rust/C) that exec's SSH — preserves PTY
- Shell wrapper: `#!/bin/sh\nexec ssh -tt root@host tmux attach -t pair-$1`
- Pipe pair's output to `sh`: `pair pi | sh` for one-command SSH attach
- Local ttyd connecting to remote? Like a terminal-based WebSocket client
