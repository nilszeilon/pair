defmodule Pair.HTTPServerTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias Pair.HTTPServer

  setup do
    case Process.whereis(Pair.SessionRegistry) do
      nil ->
        {:ok, _} = Registry.start_link(keys: :unique, name: Pair.SessionRegistry)
      _ -> :ok
    end

    case Process.whereis(Pair.SessionSupervisor) do
      nil ->
        {:ok, _} = DynamicSupervisor.start_link(strategy: :one_for_one, name: Pair.SessionSupervisor)
      _ -> :ok
    end

    :ok
  end

  describe "POST /sessions" do
    test "starts a session and returns state" do
      root = "/tmp/pair-http-test-#{:rand.uniform(999)}"

      body = Jason.encode!(%{"root_path" => root, "agent" => "echo"})

      conn =
        conn(:post, "/sessions", body)
        |> put_req_header("content-type", "application/json")
        |> HTTPServer.call(HTTPServer.init([]))

      assert conn.status == 201
      {:ok, decoded} = Jason.decode(conn.resp_body)
      assert decoded["root_path"] == root
      assert decoded["agent"] == "echo"
      assert Map.has_key?(decoded, "id")
      assert Map.has_key?(decoded, "url")
      assert Map.has_key?(decoded, "started_at")
    end

    test "defaults agent to pi" do
      body = Jason.encode!(%{"root_path" => "/tmp"})

      conn =
        conn(:post, "/sessions", body)
        |> put_req_header("content-type", "application/json")
        |> HTTPServer.call(HTTPServer.init([]))

      assert conn.status == 201
      {:ok, decoded} = Jason.decode(conn.resp_body)
      assert decoded["agent"] == "pi"
    end

    test "resolves ~ in path" do
      body = Jason.encode!(%{"root_path" => "~", "agent" => "echo"})

      conn =
        conn(:post, "/sessions", body)
        |> put_req_header("content-type", "application/json")
        |> HTTPServer.call(HTTPServer.init([]))

      assert conn.status == 201
      {:ok, decoded} = Jason.decode(conn.resp_body)
      assert decoded["root_path"] == System.user_home!()
    end

    test "keeps absolute paths as-is" do
      conn =
        conn(:post, "/sessions", Jason.encode!(%{"root_path" => "/tmp/foo", "agent" => "echo"}))
        |> put_req_header("content-type", "application/json")
        |> HTTPServer.call(HTTPServer.init([]))

      assert conn.status == 201
      {:ok, decoded} = Jason.decode(conn.resp_body)
      assert decoded["root_path"] == "/tmp/foo"
    end
  end

  describe "GET /session/:id" do
    test "returns session state" do
      id = "http-test-get-#{:rand.uniform(999)}"
      root = "/tmp/pair-http-test-get-#{id}"

      HTTPServer.start_session(id, root, "echo")

      conn = conn(:get, "/session/#{id}") |> HTTPServer.call(HTTPServer.init([]))

      assert conn.status == 200
      {:ok, decoded} = Jason.decode(conn.resp_body)
      assert decoded["id"] == id
      assert decoded["root_path"] == root
    end
  end

  describe "DELETE /session/:id" do
    test "stops a session" do
      id = "http-test-delete-#{:rand.uniform(999)}"
      root = "/tmp/pair-http-test-delete-#{id}"

      HTTPServer.start_session(id, root, "echo")

      conn = conn(:delete, "/session/#{id}") |> HTTPServer.call(HTTPServer.init([]))

      assert conn.status == 200
      {:ok, decoded} = Jason.decode(conn.resp_body)
      assert decoded["status"] == "stopped"
      assert decoded["session_id"] == id
    end
  end

  describe "GET /" do
    test "returns dashboard HTML" do
      conn = conn(:get, "/") |> HTTPServer.call(HTTPServer.init([]))

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> List.first() =~ "text/html"
      assert conn.resp_body =~ "<title>Pair"
      assert conn.resp_body =~ "new-session-form"
      assert conn.resp_body =~ "session-list"
    end
  end

  describe "GET /sessions" do
    test "returns JSON session list" do
      conn = conn(:get, "/sessions") |> HTTPServer.call(HTTPServer.init([]))
      assert conn.status == 200
      {:ok, sessions} = Jason.decode(conn.resp_body)
      assert is_list(sessions)
    end

    test "includes sessions started via POST" do
      root = "/tmp/pair-http-list-#{:rand.uniform(999)}"

      conn(:post, "/sessions", Jason.encode!(%{"root_path" => root, "agent" => "echo"}))
      |> put_req_header("content-type", "application/json")
      |> HTTPServer.call(HTTPServer.init([]))

      conn = conn(:get, "/sessions") |> HTTPServer.call(HTTPServer.init([]))
      assert conn.status == 200
      {:ok, sessions} = Jason.decode(conn.resp_body)
      assert length(sessions) >= 1
      assert Enum.any?(sessions, &(&1["root_path"] == root))
    end
  end

  describe "GET /health" do
    test "returns ok" do
      conn = conn(:get, "/health") |> HTTPServer.call(HTTPServer.init([]))
      assert conn.status == 200
      assert conn.resp_body == "ok"
    end
  end
end
