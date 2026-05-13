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

  describe "GET / (HTML for browsers)" do
    test "returns HTML when Accept: text/html" do
      conn =
        conn(:get, "/")
        |> put_req_header("accept", "text/html,application/xhtml+xml")
        |> HTTPServer.call(HTTPServer.init([]))

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> List.first() =~ "text/html"
      # Key HTML elements
      assert conn.resp_body =~ "<title>Pair"
      assert conn.resp_body =~ "new-session-form"
      assert conn.resp_body =~ "session-list"
      assert conn.resp_body =~ "browse-modal"
      assert conn.resp_body =~ "browse-btn"
    end

    test "returns JSON when no HTML accept header" do
      conn = conn(:get, "/") |> HTTPServer.call(HTTPServer.init([]))
      assert conn.status == 200
      {:ok, sessions} = Jason.decode(conn.resp_body)
      assert is_list(sessions)
    end
  end

  describe "GET /sessions" do
    test "returns JSON session list" do
      conn = conn(:get, "/sessions") |> HTTPServer.call(HTTPServer.init([]))
      assert conn.status == 200
      {:ok, sessions} = Jason.decode(conn.resp_body)
      assert is_list(sessions)
    end

    test "returns JSON even with HTML accept header" do
      conn =
        conn(:get, "/sessions")
        |> put_req_header("accept", "text/html")
        |> HTTPServer.call(HTTPServer.init([]))

      assert conn.status == 200
      {:ok, _} = Jason.decode(conn.resp_body)
    end
  end

  describe "POST /session/:id/start (path resolution)" do
    test "resolves ~ to home directory" do
      id = "http-test-tilde-#{:rand.uniform(999)}"
      body = Jason.encode!(%{"root_path" => "~", "agent" => "echo"})

      conn =
        conn(:post, "/session/#{id}/start", body)
        |> put_req_header("content-type", "application/json")
        |> HTTPServer.call(HTTPServer.init([]))

      assert conn.status == 201
      {:ok, decoded} = Jason.decode(conn.resp_body)
      assert decoded["root_path"] == System.user_home!()
    end

    test "resolves ~/subdir to home subdirectory" do
      id = "http-test-tilde-sub-#{:rand.uniform(999)}"
      body = Jason.encode!(%{"root_path" => "~/Documents", "agent" => "echo"})

      conn =
        conn(:post, "/session/#{id}/start", body)
        |> put_req_header("content-type", "application/json")
        |> HTTPServer.call(HTTPServer.init([]))

      assert conn.status == 201
      {:ok, decoded} = Jason.decode(conn.resp_body)
      assert decoded["root_path"] == Path.join(System.user_home!(), "Documents")
    end

    test "resolves relative path from home" do
      id = "http-test-rel-#{:rand.uniform(999)}"
      body = Jason.encode!(%{"root_path" => "dev", "agent" => "echo"})

      conn =
        conn(:post, "/session/#{id}/start", body)
        |> put_req_header("content-type", "application/json")
        |> HTTPServer.call(HTTPServer.init([]))

      assert conn.status == 201
      {:ok, decoded} = Jason.decode(conn.resp_body)
      assert decoded["root_path"] == Path.join(System.user_home!(), "dev")
    end

    test "keeps absolute paths as-is" do
      id = "http-test-abs-#{:rand.uniform(999)}"

      conn =
        conn(:post, "/session/#{id}/start", Jason.encode!(%{"root_path" => "/tmp/foo", "agent" => "echo"}))
        |> put_req_header("content-type", "application/json")
        |> HTTPServer.call(HTTPServer.init([]))

      assert conn.status == 201
      {:ok, decoded} = Jason.decode(conn.resp_body)
      assert decoded["root_path"] == "/tmp/foo"
    end
  end

  describe "GET /browse" do
    test "returns directory listing for valid path" do
      conn = conn(:get, "/browse?path=/tmp") |> HTTPServer.call(HTTPServer.init([]))
      assert conn.status == 200
      {:ok, data} = Jason.decode(conn.resp_body)
      assert data["path"] == "/tmp"
      assert is_list(data["entries"])
      for e <- data["entries"] do
        assert Map.has_key?(e, "name")
        assert e["type"] in ["dir", "file"]
      end
    end

    test "resolves ~ to home directory" do
      conn = conn(:get, "/browse?path=~") |> HTTPServer.call(HTTPServer.init([]))
      assert conn.status == 200
      {:ok, data} = Jason.decode(conn.resp_body)
      assert data["path"] == System.user_home!()
      assert is_list(data["entries"])
    end

    test "resolves ~/subdir correctly" do
      conn = conn(:get, "/browse?path=~/Documents") |> HTTPServer.call(HTTPServer.init([]))
      assert conn.status == 200
      {:ok, data} = Jason.decode(conn.resp_body)
      assert data["path"] == Path.join(System.user_home!(), "Documents")
    end

    test "defaults to home when no path given" do
      conn = conn(:get, "/browse") |> HTTPServer.call(HTTPServer.init([]))
      assert conn.status == 200
      {:ok, data} = Jason.decode(conn.resp_body)
      assert data["path"] == System.user_home!()
    end

    test "returns empty entries for non-existent path" do
      conn = conn(:get, "/browse?path=/nonexistent_xyzzy_999") |> HTTPServer.call(HTTPServer.init([]))
      assert conn.status == 200
      {:ok, data} = Jason.decode(conn.resp_body)
      assert data["entries"] == []
    end

    test "hides dotfiles" do
      conn = conn(:get, "/browse?path=~") |> HTTPServer.call(HTTPServer.init([]))
      assert conn.status == 200
      {:ok, data} = Jason.decode(conn.resp_body)
      for e <- data["entries"] do
        refute String.starts_with?(e["name"], ".")
      end
    end
  end
end
