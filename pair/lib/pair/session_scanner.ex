defmodule Pair.SessionScanner do
  @moduledoc """
  Discovers tmux sessions on pair's socket and adopts them.

  Polls `tmux -L pair list-sessions` every 10 seconds. Any session on
  the pair socket that isn't already managed gets adopted — ttyd is
  started and health monitoring begins.

  The user controls what's shared: `tmux -L pair new -s mysession pi`
  puts it on pair's socket. Regular `tmux` sessions are invisible.
  """

  use GenServer

  require Logger
  defp debug?, do: System.get_env("PAIR_DEBUG") == "1"

  @socket_args ["-L", "pair"]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    schedule_scan()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:scan, state) do
    scan()
    schedule_scan()
    {:noreply, state}
  end

  defp scan do
    managed = managed_ids()

    list_sessions()
    |> Enum.each(fn {name, cmd, path} ->
      if name not in managed do
        agent = Path.basename(cmd)
        if debug?(), do: Logger.debug("Scanner adopting #{name} (#{agent} in #{path})")
        DynamicSupervisor.start_child(
          Pair.SessionSupervisor,
          {Pair.SessionServer, id: name, root_path: path, agent: agent, adopt: true}
        )
      end
    end)
  end

  defp managed_ids do
    Pair.SessionRegistry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> MapSet.new()
  end

  defp list_sessions do
    fmt = ~S(#{session_name} #{pane_current_command} #{pane_current_path})
    case System.cmd("tmux", @socket_args ++ ["list-sessions", "-F", fmt], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.trim()
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(fn line ->
          case String.split(line, " ", parts: 3) do
            [name, cmd, path] -> {name, cmd, path}
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
      _ -> []
    end
  end

  defp schedule_scan do
    Process.send_after(self(), :scan, 10_000)
  end
end
