defmodule Mix.Tasks.Pair do
  @moduledoc """
  Fault-tolerant, shareable agent sessions.

  ## Server (run once)
      pair server              Start the orchestrator daemon

  ## Client (any terminal, talks to running server)
      pair start pi            Start a pi session in current directory
      pair start pi /path      Start pi in /path
      pair start claude .      Start Claude Code in current directory
      pair list                List all active sessions
      pair join myproject      Get URL for existing session
      pair stop myproject      Stop a session

  Credentials forwarded automatically. Use KEY=sk-... to pass a key.
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

  @credential_vars ~w(
    ANTHROPIC_API_KEY OPENAI_API_KEY GOOGLE_API_KEY
    GEMINI_API_KEY DEEPSEEK_API_KEY GROQ_API_KEY
    OPENROUTER_API_KEY TOGETHER_API_KEY
    VERTEX_AI_CREDENTIALS GOOGLE_APPLICATION_CREDENTIALS
    COHERE_API_KEY MISTRAL_API_KEY
    API_KEY
  )

  # Git credentials — forwarded so agent can commit on server
  @git_vars ~w(
    GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL
    GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
    GIT_SSH_COMMAND
  )

  def run(args) do
    case args do
      ["server" | _] -> server()
      ["connect", host] -> connect(host)
      ["start" | rest] -> start(rest)
      ["list"] -> list()
      ["join" | rest] -> join(rest)
      ["stop" | rest] -> stop(rest)
      [agent | rest] -> start([agent | rest])
      [] ->
        IO.puts("""
        Usage:
          pair server              Start orchestrator daemon
          pair connect <host>      Set default server
          pair pi                  Start pi in current dir
          pair claude /path        Start Claude in /path
          pair list                List sessions
          pair join <name>         Join session
          pair stop <name>         Stop session
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
    id = Path.basename(root_path) <> "-#{:rand.uniform(999)}"
    creds = detect_creds()
    env = creds

    body = Jason.encode!(%{root_path: root_path, env: env, agent: agent, host: server_host()})

    case api_post("session/#{id}/start", body) do
      {:ok, resp} ->
        url = resp["url"]

        if System.get_env("TMUX") != nil do
          if server_host() == "127.0.0.1" do
            # Local: switch client to agent session
            cmd = "while ! tmux has-session -t pair-#{id} 2>/dev/null; do sleep 0.2; done; " <>
                  "tmux switch-client -t pair-#{id}"
            System.cmd("sh", ["-c", cmd])
          else
            # Remote: try SSH into tmux, fallback to browser
            host = server_host()
            IO.puts("Connecting to #{host} ...")
            attach_remote(host, id, url)
          end
        else
          if server_host() == "127.0.0.1" do
            # Local: attach directly
            System.cmd("tmux", ["attach", "-t", "pair-#{id}"], into: IO.stream(:stdio, :line))
          else
            # Remote: try SSH into tmux, fallback to browser
            host = server_host()
            IO.puts("Connecting to #{host} ...")
            attach_remote(host, id, url)
          end
        end

      {:error, reason} ->
        IO.puts("Failed: #{inspect(reason)}")
        IO.puts("Is the orchestrator running? Run: pair server")
    end
  end

  defp list do
    case api_get("") do
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
          id = Path.basename(File.cwd!()) <> "-#{:rand.uniform(999)}"
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

  defp detect_creds do
    creds = %{}

    creds = case System.get_env("KEY") do
      nil -> creds
      key ->
        IO.puts("   Forwarding KEY=#{String.slice(key, 0, 10)}...")
        Map.put(creds, "API_KEY", key)
    end

    Enum.reduce(@credential_vars, creds, fn var, acc ->
      case System.get_env(var) do
        nil -> acc
        val ->
          unless Map.has_key?(acc, var), do: Map.put(acc, var, val), else: acc
      end
    end)
    |> then(fn acc ->
      # Git credentials
      acc = Enum.reduce(@git_vars, acc, fn var, inner_acc ->
        case System.get_env(var) do
          nil -> inner_acc
          val -> Map.put(inner_acc, var, val)
        end
      end)
      acc
    end)
  end
end
