defmodule Pair.HTTPServerTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias Pair.HTTPServer

  setup do
    # Ensure registry and supervisor are started
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

  describe "POST /session/:id/start" do
    test "starts a session and returns state with root_path" do
      id = "http-test-#{:rand.uniform(999)}"
      root = "/tmp/pair-http-test-#{id}"

      body = Jason.encode!(%{
        "root_path" => root,
        "env" => %{},
        "agent" => "echo",
        "host" => "127.0.0.1"
      })

      conn =
        conn(:post, "/session/#{id}/start", body)
        |> put_req_header("content-type", "application/json")
        |> HTTPServer.call(HTTPServer.init([]))

      assert conn.status == 201

      {:ok, decoded} = Jason.decode(conn.resp_body)
      assert decoded["root_path"] == root
      assert decoded["id"] == id
      assert decoded["agent"] == "echo"
      assert Map.has_key?(decoded, "url")
      assert Map.has_key?(decoded, "started_at")
    end

    test "defaults to current directory when root_path not provided" do
      id = "http-test-default-#{:rand.uniform(999)}"

      body = Jason.encode!(%{
        "agent" => "echo"
      })

      conn =
        conn(:post, "/session/#{id}/start", body)
        |> put_req_header("content-type", "application/json")
        |> HTTPServer.call(HTTPServer.init([]))

      assert conn.status == 201

      {:ok, decoded} = Jason.decode(conn.resp_body)
      assert decoded["root_path"] == File.cwd!()
    end

    test "returns 200 if session already exists" do
      id = "http-test-exists-#{:rand.uniform(999)}"
      root = "/tmp/pair-http-test-exists-#{id}"

      body = Jason.encode!(%{
        "root_path" => root,
        "env" => %{},
        "agent" => "echo",
        "host" => "127.0.0.1"
      })

      # First request
      conn1 =
        conn(:post, "/session/#{id}/start", body)
        |> put_req_header("content-type", "application/json")
        |> HTTPServer.call(HTTPServer.init([]))
      assert conn1.status == 201

      # Second request — already started
      conn2 =
        conn(:post, "/session/#{id}/start", body)
        |> put_req_header("content-type", "application/json")
        |> HTTPServer.call(HTTPServer.init([]))

      assert conn2.status == 200

      {:ok, decoded} = Jason.decode(conn2.resp_body)
      assert decoded["status"] == "already_running"
      assert decoded["root_path"] == root
    end

    test "forwards host env to session" do
      id = "http-test-host-#{:rand.uniform(999)}"
      root = "/tmp/pair-http-test-host-#{id}"

      body = Jason.encode!(%{
        "root_path" => root,
        "env" => %{},
        "agent" => "echo",
        "host" => "tailscale.example.com"
      })

      conn =
        conn(:post, "/session/#{id}/start", body)
        |> put_req_header("content-type", "application/json")
        |> HTTPServer.call(HTTPServer.init([]))

      assert conn.status == 201

      {:ok, decoded} = Jason.decode(conn.resp_body)
      # The URL should contain the host
      assert decoded["url"] =~ "tailscale.example.com"
    end
  end

  describe "GET /session/:id" do
    test "returns session state" do
      id = "http-test-get-#{:rand.uniform(999)}"
      root = "/tmp/pair-http-test-get-#{id}"

      # Start a session first
      body = Jason.encode!(%{
        "root_path" => root,
        "env" => %{},
        "agent" => "echo",
        "host" => "127.0.0.1"
      })

      conn(:post, "/session/#{id}/start", body)
      |> put_req_header("content-type", "application/json")
      |> HTTPServer.call(HTTPServer.init([]))

      # Now GET it
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

      # Start a session
      body = Jason.encode!(%{
        "root_path" => root,
        "env" => %{},
        "agent" => "echo",
        "host" => "127.0.0.1"
      })

      conn(:post, "/session/#{id}/start", body)
      |> put_req_header("content-type", "application/json")
      |> HTTPServer.call(HTTPServer.init([]))

      # Delete it
      conn = conn(:delete, "/session/#{id}") |> HTTPServer.call(HTTPServer.init([]))

      assert conn.status == 200
      {:ok, decoded} = Jason.decode(conn.resp_body)
      assert decoded["status"] == "stopped"
      assert decoded["session_id"] == id
    end
  end

  describe "GET /" do
    test "returns list of sessions (may include sessions from other tests)" do
      conn = conn(:get, "/") |> HTTPServer.call(HTTPServer.init([]))

      assert conn.status == 200
      {:ok, sessions} = Jason.decode(conn.resp_body)
      assert is_list(sessions)
      # Each session must have required keys
      for s <- sessions do
        assert Map.has_key?(s, "id")
        assert Map.has_key?(s, "root_path")
        assert Map.has_key?(s, "url")
      end
    end

    test "lists active sessions" do
      id = "http-test-list-#{:rand.uniform(999)}"
      root = "/tmp/pair-http-test-list-#{id}"

      body = Jason.encode!(%{
        "root_path" => root,
        "env" => %{},
        "agent" => "echo",
        "host" => "127.0.0.1"
      })

      conn(:post, "/session/#{id}/start", body)
      |> put_req_header("content-type", "application/json")
      |> HTTPServer.call(HTTPServer.init([]))

      conn = conn(:get, "/") |> HTTPServer.call(HTTPServer.init([]))
      assert conn.status == 200

      {:ok, sessions} = Jason.decode(conn.resp_body)
      assert length(sessions) >= 1

      session = Enum.find(sessions, &(&1["id"] == id))
      assert session != nil
      assert session["root_path"] == root
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
