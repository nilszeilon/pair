defmodule Pair.SessionScanner do
  @moduledoc """
  Discovers tmux sessions running known agents and adopts them into pair.

  Polls `tmux list-sessions` every 10 seconds. When it finds a session
  whose foreground process matches a known agent (and isn't already managed
  by pair), it starts ttyd for it and begins health monitoring.

  Agents are configured via `PAIR_AGENTS` env var (comma-separated).
  Defaults: pi, claude, codex, aider.
  """

  use GenServer

  require Logger
  defp debug?, do: System.get_env("PAIR_DEBUG") == "1"

  @default_agents ~w(pi claude codex aider)

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
    adopted = managed_ids()

    list_sessions()
    |> Enum.reject(fn {name, _, _} ->
      # Skip sessions already named "pair-*" — they're ours
      String.starts_with?(name, "pair-")
    end)
    |> Enum.each(fn {name, cmd, path} ->
      id = name
      if id not in adopted do
        agent = matching_agent(cmd)
        if agent do
          if debug?(), do: Logger.debug("Scanner adopting #{name} (#{agent} in #{path})")
          adopt(id, path, agent)
        end
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
    case System.cmd("tmux", ["list-sessions", "-F", fmt], stderr_to_stdout: true) do
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

  defp matching_agent(command) do
    agents = agents_from_env()
    basename = Path.basename(command)
    Enum.find(agents, fn a -> basename == a or String.contains?(command, "/#{a}") end)
  end

  defp agents_from_env do
    case System.get_env("PAIR_AGENTS") do
      nil -> @default_agents
      str -> str |> String.split(",") |> Enum.map(&String.trim/1)
    end
  end

  defp adopt(id, root_path, agent) do
    DynamicSupervisor.start_child(
      Pair.SessionSupervisor,
      {Pair.SessionServer, id: id, root_path: root_path, env: %{}, agent: agent, adopt: true}
    )
  end

  defp schedule_scan do
    Process.send_after(self(), :scan, 10_000)
  end
end
