defmodule Pair do
  @moduledoc """
  Fault-tolerant, shareable coding agent sessions.

  Each session wraps an agent in a locked-down tmux session served via ttyd.
  Sessions survive disconnects, crash on non-zero exit triggers auto-restart,
  and clean exits (0) stop the session.

  Start with `mix pair server`, create sessions with `pair pi`.
  Open http://localhost:4242 for the dashboard.
  """

  def list_sessions do
    Registry.select(Pair.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
end
