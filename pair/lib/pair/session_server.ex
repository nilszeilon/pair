defmodule Pair.SessionServer do
  @moduledoc """
  Fault-tolerant pi session orchestrator.

  Manages a tmux session containing a pi process. If the user disconnects,
  pi keeps running inside tmux. If pi crashes, it's restarted automatically.
  """

  use GenServer

  require Logger
  defp debug?, do: System.get_env("PAIR_DEBUG") == "1"

  require Logger

  # ── Client API ──────────────────────────────────────────────────────

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    root_path = Keyword.fetch!(opts, :root_path)
    env = Keyword.get(opts, :env, %{})
    agent = Keyword.get(opts, :agent, "pi")
    GenServer.start_link(__MODULE__, {id, root_path, env, agent}, name: via(id))
  end

  def get_state(id), do: GenServer.call(via(id), :get_state)
  def stop(id), do: GenServer.stop(via(id))

  # ── Server ──────────────────────────────────────────────────────────

  @impl true
  def init({id, root_path, env, agent}) do
    if debug?(), do: Logger.info("SessionServer.init id=#{id} root=#{root_path} env_keys=#{inspect(Map.keys(env))}")
    session_name = "pair-#{id}"

    # Kill existing session with same name if any
    System.cmd("tmux", ["kill-session", "-t", session_name], stderr_to_stdout: true)

    # Build env exports and resolve agent binary
    env_exports = build_env_exports(Map.delete(env, "PAIR_AGENT_BIN"))
    # Always find pi on the server. Client's binary path is irrelevant.
    agent_bin = System.find_executable(agent) || agent

    # Use a dedicated session file so restarts always resume the right conversation
    session_file = "/tmp/pair-sessions/#{id}.jsonl"
    File.mkdir_p!("/tmp/pair-sessions")
    # Ensure the working directory exists
    File.mkdir_p!(root_path)

    # For pi: use --session to pin to a specific file (not --continue which picks latest)
    agent_cmd = if String.contains?(agent_bin, "pi") do
      "#{agent_bin} --session #{session_file}"
    else
      agent_bin
    end

    cmd =
      if env_exports != "" do
        "cd #{escape(root_path)} && #{env_exports} && exec #{agent_cmd}"
      else
        "cd #{escape(root_path)} && exec #{agent_cmd}"
      end
    if debug?(), do: Logger.info("Starting tmux: #{String.slice(cmd, 0, 150)}")
    {output, status} =
      System.cmd("tmux", [
        "new-session", "-d", "-s", session_name,
        "sh", "-c", cmd
      ], stderr_to_stdout: true)

    if status != 0 do
      Logger.error("tmux failed: #{String.trim(output)}")
    end

    # Start ttyd for this session (if not already running)
    ttyd_port = ensure_ttyd(session_name)

    # Customize tmux status bar with connection info
    set_tmux_status(session_name, id, ttyd_port, Map.get(env, "HOST", "unknown"))

    # Start health checker
    schedule_health_check()

    state = %{
      id: id,
      root_path: root_path,
      env: env,
      agent: agent,
      agent_bin: agent_bin,
      session_file: session_file,
      client_host: Map.get(env, "HOST"),
      tmux_session: session_name,
      ttyd_port: ttyd_port,
      started_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    pi_alive = pi_running?(state.tmux_session)
    bind = System.get_env("BIND", "127.0.0.1")
    # Use client-provided host, or PAIR_HOST, or detected hostname
    host = state[:client_host] || resolve_host(bind)
    url = "http://#{host}:#{state.ttyd_port}"

    {:reply,
      %{
        id: state.id,
        agent: state.agent,
        root_path: state.root_path,
        tmux_session: state.tmux_session,
        url: url,
        pi_alive: pi_alive,
        started_at: state.started_at
      }, state}
  end

  # Periodic health check — restart pi if it died
  @impl true
  def handle_info(:health_check, state) do
    running = pi_running?(state.tmux_session)
    if debug?(), do: Logger.debug("health_check #{state.tmux_session} running=#{running}")
    unless running do
      Logger.warning("agent died in session #{state.tmux_session}, restarting...")
      restart_agent(state)
    end

    schedule_health_check()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    # Optionally kill tmux session on GenServer shutdown
    # System.cmd("tmux", ["kill-session", "-t", state.tmux_session], stderr: :discard)
    :ok
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp via(id), do: {:via, Registry, {Pair.SessionRegistry, id}}

  defp escape(path), do: String.replace(path, "'", "'\\''")

  defp server_hostname do
    {:ok, hostname} = :inet.gethostname()
    List.to_string(hostname)
  rescue
    _ -> "localhost"
  end

  defp resolve_host(bind) do
    cond do
      host = System.get_env("PAIR_HOST") -> host
      bind == "0.0.0.0" -> server_hostname()
      true -> bind
    end
  end

  defp build_env_exports(env) do
    env
    |> Enum.flat_map(fn {k, v} ->
      # Regular env var
      ["export #{k}='#{escape(v)}'"]
    end)
    |> Enum.join("; ")
  end

  defp pi_running?(session) do
    format = ~S(#{pane_pid})
    {output, 0} = System.cmd("tmux", ["list-panes", "-t", session, "-F", format])
    pid_str = String.trim(output)

    if pid_str != "" do
      # exec replaces the shell, so the pane PID IS the agent process.
      # Just check if it's still alive.
      {_, exit_code} = System.cmd("kill", ["-0", pid_str], stderr_to_stdout: true)
      exit_code == 0
    else
      false
    end
  rescue
    _ -> false
  end

  defp restart_agent(state) do
    env_exports = build_env_exports(state.env)
    agent_bin = state.agent_bin

    # Resume the exact same conversation via pinned session file
    agent_cmd = if String.contains?(agent_bin, "pi") do
      "#{agent_bin} --session #{state.session_file}"
    else
      agent_bin
    end

    cmd =
      if env_exports != "" do
        "cd #{escape(state.root_path)} && #{env_exports} && exec #{agent_cmd}"
      else
        "cd #{escape(state.root_path)} && exec #{agent_cmd}"
      end

    # Kill and recreate — simpler and more reliable than send-keys
    System.cmd("tmux", ["kill-session", "-t", state.tmux_session], stderr_to_stdout: true)
    System.cmd("tmux", [
      "new-session", "-d", "-s", state.tmux_session,
      "sh", "-c", cmd
    ], stderr_to_stdout: true)

    set_tmux_status(state.tmux_session, state.id, state.ttyd_port, Map.get(state.env, "HOST", "unknown"))

    Logger.info("Restarted agent in #{state.tmux_session}")
  rescue
    _ -> :ok
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, 10_000)
  end

  defp set_tmux_status(session_name, id, ttyd_port, host) do
    url = "http://#{host}:#{ttyd_port}"
    left = " #[fg=cyan,bold]pair #{id} #[fg=default]| ssh root@#{host} tmux attach -t #{session_name} "
    right = " #[fg=green]#{url} #[fg=default] "

    # Resize to largest connected client (desktop > phone > detached default)
    System.cmd("tmux", ["set-window-option", "-t", session_name, "window-size", "largest"], stderr_to_stdout: true)
    System.cmd("tmux", ["set-window-option", "-t", session_name, "aggressive-resize", "on"], stderr_to_stdout: true)

    System.cmd("tmux", ["set-option", "-t", session_name, "status-left", left], stderr_to_stdout: true)
    System.cmd("tmux", ["set-option", "-t", session_name, "status-right", right], stderr_to_stdout: true)
    System.cmd("tmux", ["set-option", "-t", session_name, "status-style", "bg=colour236,fg=white"], stderr_to_stdout: true)
  end

  # ── ttyd management ──────────────────────────────────────────────

  defp ensure_ttyd(session_name) do
    port = allocate_port(session_name)
    bind = System.get_env("BIND", "127.0.0.1")

    # Kill any existing ttyd on this port
    System.cmd("pkill", ["-f", "ttyd.*#{port}"], stderr_to_stdout: true)

    # Start ttyd as detached background process, bound to same interface as orchestrator
    # fontSize=18: larger text, readable on phone. Default is 15.
    :os.cmd(~c'ttyd -p #{port} -i #{bind} --writable --client-option fontSize=18 tmux attach -t #{session_name} > /dev/null 2>&1 &')

    Process.sleep(500)
    port
  end

  defp allocate_port(session_name) do
    # Simple hash-based port allocation in range 4300-4399
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
