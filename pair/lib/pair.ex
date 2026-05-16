defmodule Pair do
  @moduledoc """
  Fault-tolerant, shareable coding agent sessions.

  Each session runs an agent inside a tmux session, served via ttyd.
  The GenServer monitors agent health and restarts it if it crashes.
  Sessions survive all client disconnects — reconnect from any device.
  """

  def list_sessions do
    Registry.select(Pair.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
end
