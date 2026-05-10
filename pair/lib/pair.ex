defmodule Pair do
  @moduledoc """
  Fault-tolerant, shareable pi sessions.

  ## CLI

      mix pi                    # Start in current directory
      mix pi myproject          # Named session
      mix pi myproject /path/to/project

  ## Architecture

  Each session runs pi inside a tmux session, served via ttyd.
  The GenServer monitors pi's health and restarts it if it crashes.
  Sessions survive all client disconnects — reconnect from any device.

  See GUIDING_LIGHTS.md for the full vision.
  """

  def list_sessions do
    Registry.select(Pair.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
end
