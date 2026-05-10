defmodule Pair.HTTPServer do
  @moduledoc """
  REST API for the pi session orchestrator.
  """

  use Plug.Router

  require Logger
  defp debug?, do: System.get_env("PAIR_DEBUG") == "1"

  plug(:match)
  plug(:fetch_query_params)
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  # List all sessions
  get "/" do
    sessions =
      Pair.SessionRegistry
      |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Enum.map(fn id ->
        Pair.SessionServer.get_state(id)
      end)

    send_resp(conn, 200, Jason.encode!(sessions, pretty: true))
  end

  # Start a new session
  post "/session/:id/start" do
    {:ok, body, conn} = read_body(conn)
    require Logger
    if debug?(), do: Logger.info("POST /session/#{id}/start body=#{String.slice(body, 0, 200)}")
    {root_path, env, agent} =
      case Jason.decode(body) do
        {:ok, %{"root_path" => path} = params} ->
          env = Map.get(params, "env", %{})
          host = Map.get(params, "host", "")
          env = if host != "", do: Map.put(env, "HOST", host), else: env
          {path, env, Map.get(params, "agent", "pi")}
        _ -> {File.cwd!(), %{}, "pi"}
      end

    case start_session(id, root_path, env, agent) do
      {:ok, _pid} ->
        state = Pair.SessionServer.get_state(id)
        send_resp(conn, 201, Jason.encode!(Map.merge(%{status: "started"}, state), pretty: true))

      {:error, {:already_started, _pid}} ->
        state = Pair.SessionServer.get_state(id)
        send_resp(conn, 200, Jason.encode!(Map.merge(%{status: "already_running"}, state), pretty: true))

      {:error, reason} ->
        send_resp(conn, 500, Jason.encode!(%{error: inspect(reason)}))
    end
  end

  # Get session state
  get "/session/:id" do
    state = Pair.SessionServer.get_state(id)
    send_resp(conn, 200, Jason.encode!(state, pretty: true))
  end

  # Stop a session
  delete "/session/:id" do
    Pair.SessionServer.stop(id)
    send_resp(conn, 200, Jason.encode!(%{status: "stopped", session_id: id}))
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "not found"}))
  end

  def start_session(id, root_path, env \\ %{}, agent \\ "pi") do
    DynamicSupervisor.start_child(
      Pair.SessionSupervisor,
      {Pair.SessionServer, id: id, root_path: root_path, env: env, agent: agent}
    )
  end
end
