defmodule Mix.Tasks.Pair do
  @moduledoc """
  Shareable, fault-tolerant coding agent sessions.

  See the Go client (pair) for the primary CLI. This mix task
  is an alternative for Elixir users.
  """

  use Mix.Task

  require Logger
  defp debug?, do: System.get_env("PAIR_DEBUG") == "1"

  @shortdoc "Manage agent sessions"
  @server_port System.get_env("PAIR_PORT", "4242")

  defp server_host do
    # 1. Env var override
    case System.get_env("PAIR_HOST") do
      nil ->
        # 2. Config file
        config = Path.join(config_dir(), "host")
        if File.exists?(config) do
          String.trim(File.read!(config))
        else
          "127.0.0.1"
        end
      host -> host
    end
  end

  defp config_dir do
    dir = Path.join(System.user_home!(), ".pair")
    File.mkdir_p!(dir)
    dir
  end

  def run(args) do
    case args do
      ["server" | _] -> server()
      ["connect", host] -> connect(host)
      ["start" | rest] -> start(rest)
      ["list"] -> list()
      ["join" | rest] -> join(rest)
      ["stop" | rest] -> stop(rest)
      ["remote" | rest] -> start(rest)  # mix task: remote same as start
      [agent | rest] -> start([agent | rest])
      [] ->
        IO.puts("""
        Usage:
          pair pi                  Start pi locally
          pair connect <host>      Set remote server
          pair remote pi           Start pi on remote server
          pair list                List sessions
          pair browse              Interactive picker
          pair join <name>         Reconnect (partial match OK)
          pair stop <name>         Stop a session
        """)
    end
  end

  # ── Server ──────────────────────────────────────────────────────

  defp server do
    {:ok, _} = Application.ensure_all_started(:pair)
    bind = System.get_env("BIND", "127.0.0.1")
    IO.puts("Orchestrator running at http://#{bind}:#{@server_port}")
    IO.puts("Use 'pair pi' from another terminal.")
    Process.sleep(:infinity)
  end

  # ── Connect ────────────────────────────────────────────────────

  defp connect(host) do
    File.write!(Path.join(config_dir(), "host"), host)
    IO.puts("Server set to #{host}")
  end

  # ── Client commands (talk to server via HTTP) ───────────────────

  defp start(args) do
    {agent, root_path} = parse_start_args(args)

    if server_host() != "127.0.0.1" do
      IO.puts("Starting fresh session on #{server_host()}")
      IO.puts("  SSH to the server and run 'pair pi' in your project to use existing code.")
    end

    body = Jason.encode!(%{
      root_path: root_path,
      env: %{},
      agent: agent,
      host: server_host()
    })

    case api_post("sessions", body) do
      {:ok, resp} ->
        id = resp["id"]
        handle_start_response(resp, id)

      {:error, reason} ->
        # Local: try auto-starting the server
        if server_host() == "127.0.0.1" do
          IO.puts("Server not running — starting it now...")
          {_, 0} = System.cmd("sh", ["-c", "cd #{find_project_root()} && mix pair server &"],
                              stderr_to_stdout: true)
          # Wait for it to come up
          Enum.reduce_while(1..20, nil, fn _, _ ->
            Process.sleep(500)
            case api_get("health") do
              {:ok, _} -> {:halt, :ok}
              _ -> {:cont, nil}
            end
          end)
          # Retry
          case api_post("sessions", body) do
            {:ok, resp} ->
              id = resp["id"]
              handle_start_response(resp, id)
            _ ->
              IO.puts("Server started but still unreachable. Check 'mix pair server' manually.")
          end
        else
          IO.puts("Failed: #{inspect(reason)}")
          IO.puts("Is the orchestrator running? Run: pair server")
        end
    end
  end

  defp handle_start_response(resp, id) do
    url = resp["url"]
    if System.get_env("TMUX") != nil do
      if server_host() == "127.0.0.1" do
        cmd = "while ! tmux has-session -t pair-#{id} 2>/dev/null; do sleep 0.2; done; " <>
              "tmux switch-client -t pair-#{id}"
        System.cmd("sh", ["-c", cmd])
      else
        host = server_host()
        IO.puts("Connecting to #{host} ...")
        attach_remote(host, id, url)
      end
    else
      if server_host() == "127.0.0.1" do
        System.cmd("tmux", ["attach", "-t", "pair-#{id}"], into: IO.stream(:stdio, :line))
      else
        host = server_host()
        IO.puts("Connecting to #{host} ...")
        attach_remote(host, id, url)
      end
    end
  end

  defp find_project_root do
    # Walk up from cwd looking for mix.exs with "Pair"
    dir = File.cwd!()
    root = Enum.find_value(Stream.iterate(dir, &Path.dirname/1), fn d ->
      mix = Path.join(d, "mix.exs")
      if File.exists?(mix) and String.contains?(File.read!(mix), "Pair"), do: d
    end)
    # Fallback: common locations
    root || Enum.find([
      Path.join(System.user_home!(), "dev/pair/pair"),
      Path.join(System.user_home!(), "dev/pair"),
      Path.join(System.user_home!(), "dev/everywhere/pair"),
      Path.join(System.user_home!(), "pair"),
      "/usr/local/lib/pair"
    ], &File.exists?(Path.join(&1, "mix.exs"))) || File.cwd!()
  end

  defp list do
    case api_get("sessions") do
      {:ok, sessions} when sessions == [] ->
        IO.puts("No active sessions.")
      {:ok, sessions} ->
        IO.puts("Active sessions:\n")
        Enum.each(sessions, fn s ->
          IO.puts("  #{s["id"]}")
          IO.puts("    Agent:  #{s["agent"] || "unknown"}")
          IO.puts("    URL:    #{s["url"]}")
          IO.puts("    Path:   #{s["root_path"]}")
          IO.puts("")
        end)
      {:error, reason} ->
        IO.puts("Could not reach orchestrator: #{inspect(reason)}")
        IO.puts("Run: pair server")
    end
  end

  defp join(args) do
    case args do
      [name] ->
        case api_get("session/#{name}") do
          {:ok, state} ->
            url = state["url"]
            root_path = state["root_path"]
            if System.get_env("TMUX") != nil and server_host() == "127.0.0.1" do
              # Local tmux: switch client
              has = System.cmd("tmux", ["has-session", "-t", "pair-#{name}"], stderr_to_stdout: true)
              if elem(has, 1) != 0 do
                api_delete("session/#{name}")
                Process.sleep(200)
                api_post("session/#{name}/start", Jason.encode!(%{root_path: root_path || "."}))
                Process.sleep(500)
              end
              System.cmd("tmux", ["switch-client", "-t", "pair-#{name}"])
            else
            # Remote: print SSH command, open browser
              host = server_host()
              IO.puts("Connecting to #{host} ...")
              attach_remote(host, name, url)
            end
          {:error, _} ->
            IO.puts("Session '#{name}' not found.")
        end

      _ ->
        IO.puts("Usage: pair join <name>")
    end
  end

  defp stop(args) do
    case args do
      [name] ->
        case api_delete("session/#{name}") do
          {:ok, _} -> IO.puts("Stopped session '#{name}'")
          {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
        end
      _ ->
        IO.puts("Usage: pair stop <name>")
    end
  end

  # ── HTTP helpers ─────────────────────────────────────────────────

  defp api_base, do: "http://#{server_host()}:#{@server_port}"

  defp api_get(path) do
    url = "#{api_base()}/#{path}"
    case System.cmd("curl", ["-s", url], stderr_to_stdout: true) do
      {body, 0} -> {:ok, Jason.decode!(body)}
      {_, _} -> {:error, :econnrefused}
    end
  rescue
    _ -> {:error, :econnrefused}
  end

  defp api_post(path, body) do
    url = "#{api_base()}/#{path}"
    if debug?(), do: IO.puts("   [debug] POST #{url} body=#{String.slice(body, 0, 200)}")
    case System.cmd("curl", ["-s", "-X", "POST", url,
                              "-H", "Content-Type: application/json",
                              "-d", body], stderr_to_stdout: true) do
      {resp, 0} ->
        if debug?(), do: IO.puts("   [debug] Response: #{String.slice(resp, 0, 300)}")
        {:ok, Jason.decode!(resp)}
      {resp, code} ->
        if debug?(), do: IO.puts("   [debug] Curl failed (exit #{code}): #{String.slice(resp, 0, 200)}")
        {:error, :econnrefused}
    end
  rescue
    e ->
      if debug?(), do: IO.puts("   [debug] Curl exception: #{inspect(e)}")
      {:error, :econnrefused}
  end

  defp api_delete(path) do
    url = "#{api_base()}/#{path}"
    case System.cmd("curl", ["-s", "-X", "DELETE", url], stderr_to_stdout: true) do
      {body, 0} -> {:ok, Jason.decode!(body)}
      {_, _} -> {:error, :econnrefused}
    end
  rescue
    _ -> {:error, :econnrefused}
  end

  # ── Credentials ──────────────────────────────────────────────────

  defp parse_start_args(args) do
    is_remote = server_host() != "127.0.0.1"
    case args do
      [a] ->
        if is_remote do
          id = Integer.to_string(:rand.uniform(9999)) |> String.pad_leading(4, "0")
          {a, "/tmp/pair-sessions/#{id}"}
        else
          {a, File.cwd!()}
        end

      [a, p] ->
        if is_remote do
          {a, p}
        else
          {a, Path.expand(p)}
        end

      _ ->
        IO.puts("Usage: pair <agent> [path]")
        System.halt(1)
    end
  end

  defp attach_remote(host, id, url) do
    # Strip user@ prefix for SSH
    dest = if String.contains?(host, "@"), do: host, else: "root@#{host}"
    key = Path.join(System.user_home!(), ".ssh/pair")
    key_flag = if File.exists?(key), do: "-i #{key} ", else: ""

    IO.puts("")
    IO.puts("╭─ Terminal ─────────────────────────────────────")
    IO.puts("│  ssh #{key_flag}-tt -o StrictHostKeyChecking=no #{dest} tmux attach -t pair-#{id}")
    IO.puts("╰────────────────────────────────────────────────")
    IO.puts("")
    IO.puts("Browser: #{url}")
    System.cmd("open", [url], stderr_to_stdout: true)
  end
end
