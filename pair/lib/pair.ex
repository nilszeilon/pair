defmodule Pair do
  @moduledoc """
  Fault-tolerant, shareable coding agent sessions.

  Each session wraps an agent in a tmux session served via ttyd for browser
  access. Sessions survive disconnects; health checks auto-restart crashed
  agents. Existing tmux sessions running known agents are auto-discovered.

  Start with `mix pair server` and open http://localhost:4242.
  """

  def list_sessions do
    Registry.select(Pair.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
end
