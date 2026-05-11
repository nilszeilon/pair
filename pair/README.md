# Pair Server

Fault-tolerant session orchestrator for coding agents. ~300 lines of Elixir.

Manages tmux sessions containing agent processes, served via ttyd for browser access. Sessions survive all client disconnects — health checks auto-recover crashed agents.

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

## API

```
POST   /session/:id/start   { root_path, env, agent, host }
GET    /session/:id          session state
DELETE /session/:id          stop session
GET    /                     list all sessions
GET    /health               "ok"
```

## Running

```bash
mix deps.get
mix pair server                     # localhost only
BIND=0.0.0.0 mix pair server        # accessible over network
```

## Dependencies

- Elixir ~> 1.16
- tmux (session persistence)
- ttyd (browser terminal)
