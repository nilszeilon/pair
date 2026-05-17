defmodule Pair.HTTPServer do
  @moduledoc """
  REST API for the Pair session orchestrator.
  Serves the dashboard on GET /, JSON for everything else.
  """

  use Plug.Router

  require Logger
  defp debug?, do: System.get_env("PAIR_DEBUG") == "1"

  @dashboard File.read!(Path.expand("../../dashboard.html", __DIR__))

  plug(:match)
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  # Dashboard (browser) or JSON (API clients)
  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, @dashboard)
  end

  # JSON session list (for dashboard auto-refresh and API clients)
  get "/sessions" do
    sessions = list_sessions()
    if debug?(), do: Logger.debug("GET /sessions → #{length(sessions)} sessions")
    send_resp(conn, 200, Jason.encode!(sessions))
  end

  # Start a new managed session
  post "/sessions" do
    {:ok, body, conn} = read_body(conn)
    {root_path, agent} =
      case Jason.decode(body) do
        {:ok, %{"root_path" => path, "agent" => a}} ->
          {resolve_path(path), a}
        {:ok, %{"root_path" => path}} ->
          {resolve_path(path), "pi"}
        _ ->
          {File.cwd!(), "pi"}
      end

    id = Integer.to_string(System.unique_integer([:monotonic]))
    if debug?(), do: Logger.info("POST /sessions id=#{id} root=#{root_path} agent=#{agent}")

    case start_session(id, root_path, agent) do
      {:ok, _pid} ->
        state = Pair.SessionServer.get_state(id)
        send_resp(conn, 201, Jason.encode!(Map.merge(%{status: "started"}, state)))

      {:error, {:already_started, _pid}} ->
        state = Pair.SessionServer.get_state(id)
        send_resp(conn, 200, Jason.encode!(Map.merge(%{status: "already_running"}, state)))

      {:error, reason} ->
        send_resp(conn, 500, Jason.encode!(%{error: inspect(reason)}))
    end
  end

  # Get session state
  get "/session/:id" do
    state = Pair.SessionServer.get_state(id)
    send_resp(conn, 200, Jason.encode!(state))
  end

  # Stop a session
  delete "/session/:id" do
    Pair.SessionServer.stop(id)
    send_resp(conn, 200, Jason.encode!(%{status: "stopped", session_id: id}))
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "not found"}))
  end

  def start_session(id, root_path, agent \\ "pi") do
    DynamicSupervisor.start_child(
      Pair.SessionSupervisor,
      {Pair.SessionServer, id: id, root_path: root_path, agent: agent}
    )
  end

  # ── Helpers ───────────────────────────────────────────────────────

  defp list_sessions do
    Pair.SessionRegistry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.map(fn id ->
      Pair.SessionServer.get_state(id)
    end)
  end

  defp resolve_path(path) do
    home = System.user_home!()
    cond do
      path == "~" -> home
      String.starts_with?(path, "~/") -> home <> String.replace_leading(path, "~", "")
      String.starts_with?(path, "/") -> path
      true -> Path.join(home, path)
    end
  end
end
