defmodule Pair do
  @moduledoc """
  Fault-tolerant, shareable coding agent sessions.

  Each session wraps an agent in a locked-down tmux session served via ttyd.
  Sessions survive disconnects. When the agent exits, the session is removed
  from the dashboard.

  Start with `mix pair server`, create sessions with `pair pi`.
  Open http://localhost:4242 for the dashboard.
  """
end
