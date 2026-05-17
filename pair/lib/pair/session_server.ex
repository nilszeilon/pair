defmodule Pair.SessionServer do
  @moduledoc """
  Fault-tolerant agent session orchestrator.

  Manages a tmux session on pair's own socket (`tmux -L pair`). If the
  user disconnects, the agent keeps running inside tmux. When the agent
  exits, the session is removed.

  Supports two modes:
  - Managed: pair creates the tmux session (via POST /sessions)
  - Adopted: an existing session on the pair socket is adopted by the scanner
  """

  use GenServer

  require Logger
  defp debug?, do: System.get_env("PAIR_DEBUG") == "1"

  @index_html Path.expand("../../index.html", __DIR__)
  @socket_args ["-L", "pair"]

  # ── Client API ──────────────────────────────────────────────────────

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    root_path = Keyword.fetch!(opts, :root_path)
    agent = Keyword.get(opts, :agent, "pi")
    adopt = Keyword.get(opts, :adopt, false)
    GenServer.start_link(__MODULE__, {id, root_path, agent, adopt}, name: via(id))
  end

  def get_state(id), do: GenServer.call(via(id), :get_state)
  def stop(id), do: GenServer.stop(via(id))

  # ── Server ──────────────────────────────────────────────────────────

  @impl true
  def init({id, root_path, agent, adopt}) do
    if debug?(), do: Logger.info("SessionServer.init id=#{id} adopt=#{adopt} root=#{root_path}")
    session_name = id

    unless adopt do
      # Managed: create tmux session on pair socket
      tmux(["kill-session", "-t", session_name])
      File.mkdir_p!(root_path)

      cmd = "cd #{escape(root_path)} && exec #{agent}"
      if debug?(), do: Logger.info("Starting tmux: #{cmd}")
      {output, status} =
        tmux(["new-session", "-d", "-s", session_name, "sh", "-c", cmd])

      if status != 0 do
        Logger.error("tmux failed: #{String.trim(output)}")
      end
    end

    # Lock down: no splits/windows
    tmux(["set-option", "-t", session_name, "prefix", "None"])
    tmux(["set-option", "-t", session_name, "status", "off"])

    ttyd_port = ensure_ttyd(session_name)
    schedule_health_check()

    state = %{
      id: id,
      root_path: root_path,
      agent: agent,
      adopt: adopt,
      tmux_session: session_name,
      ttyd_port: ttyd_port,
      started_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    pi_alive = pi_running?(state.tmux_session)
    bind = Application.get_env(:pair, :bind, "127.0.0.1")
    url = "http://#{bind}:#{state.ttyd_port}"

    {:reply,
      %{
        id: state.id,
        agent: state.agent,
        root_path: state.root_path,
        tmux_session: state.tmux_session,
        url: url,
        pi_alive: pi_alive,
        adopted: state[:adopt] || false,
        started_at: state.started_at
      }, state}
  end

  @impl true
  def handle_info(:health_check, state) do
    if pi_running?(state.tmux_session) do
      if debug?(), do: Logger.debug("health_check #{state.tmux_session} running")
      schedule_health_check()
      {:noreply, state}
    else
      Logger.info("Agent exited in #{state.tmux_session}, stopping")
      {:stop, :normal, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Session #{state.id} terminating (reason: #{inspect(reason)})")
    unless state[:adopt] do
      tmux(["kill-session", "-t", state.tmux_session])
      Process.sleep(200)
    end
    System.cmd("pkill", ["-f", "ttyd.*#{state.ttyd_port}"], stderr_to_stdout: true)
    :ok
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp tmux(args), do: System.cmd("tmux", @socket_args ++ args, stderr_to_stdout: true)

  defp via(id), do: {:via, Registry, {Pair.SessionRegistry, id}}

  defp escape(path), do: String.replace(path, "'", "'\\''")

  defp pane_status(session) do
    format = ~S(#{pane_dead} #{pane_pid})
    {output, 0} = tmux(["list-panes", "-t", session, "-F", format])
    [dead_str, pid_str] = String.split(String.trim(output), " ", parts: 2)

    cond do
      dead_str == "1" -> false
      pid_str == "" or pid_str == "0" -> false
      true ->
        {_, exit_code} = System.cmd("kill", ["-0", pid_str], stderr_to_stdout: true)
        exit_code == 0
    end
  rescue
    _ -> false
  end

  defp pi_running?(session), do: pane_status(session)

  defp schedule_health_check do
    Process.send_after(self(), :health_check, 10_000)
  end

  # ── ttyd management ──────────────────────────────────────────────

  defp ensure_ttyd(session_name) do
    port = allocate_port(session_name)
    bind = Application.get_env(:pair, :bind, "127.0.0.1")

    System.cmd("pkill", ["-f", "ttyd.*#{port}"], stderr_to_stdout: true)

    index_path = escape(@index_html)
    ttyd_cmd = "ttyd -p #{port} -i #{bind} --writable --index #{index_path} tmux -L pair attach -t #{session_name} > /dev/null 2>&1 &"
    :os.cmd(String.to_charlist(ttyd_cmd))

    Process.sleep(500)
    port
  end

  defp allocate_port(session_name) do
    hash = :erlang.phash2(session_name, 100)
    4300 + hash
  end

  # ── Child Spec ──────────────────────────────────────────────────────

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end
end
