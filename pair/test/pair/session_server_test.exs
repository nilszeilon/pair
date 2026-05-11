defmodule Pair.SessionServerTest do
  use ExUnit.Case, async: false

  alias Pair.SessionServer

  @moduletag :tmp_dir

  setup do
    tmp = Path.join(System.tmp_dir!(), "pair-test-#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp)
    {:ok, tmp_dir: tmp}
  end

  describe "root_path handling" do
    test "creates root_path directory if it does not exist", %{tmp_dir: tmp} do
      root = Path.join(tmp, "new-project")
      refute File.exists?(root)

      id = "test-create-#{:rand.uniform(999)}"
      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Pair.SessionSupervisor,
          {SessionServer, id: id, root_path: root, env: %{}, agent: "echo"}
        )

      assert File.dir?(root)
      SessionServer.stop(id)
    end

    test "stores root_path in session state", %{tmp_dir: tmp} do
      root = Path.join(tmp, "my-project")
      File.mkdir_p!(root)

      id = "test-state-#{:rand.uniform(999)}"
      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Pair.SessionSupervisor,
          {SessionServer, id: id, root_path: root, env: %{}, agent: "echo"}
        )

      state = SessionServer.get_state(id)
      assert state.root_path == root
      SessionServer.stop(id)
    end

    test "handles nested root_path creation", %{tmp_dir: tmp} do
      root = Path.join([tmp, "deep", "nested", "path"])
      refute File.exists?(root)

      id = "test-nested-#{:rand.uniform(999)}"
      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Pair.SessionSupervisor,
          {SessionServer, id: id, root_path: root, env: %{}, agent: "echo"}
        )

      assert File.dir?(root)
      SessionServer.stop(id)
    end

    test "returns all expected keys in get_state", %{tmp_dir: tmp} do
      root = Path.join(tmp, "myproject")
      File.mkdir_p!(root)

      id = "test-shape-#{:rand.uniform(999)}"
      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Pair.SessionSupervisor,
          {SessionServer, id: id, root_path: root, env: %{}, agent: "echo"}
        )

      state = SessionServer.get_state(id)

      assert Map.has_key?(state, :id)
      assert Map.has_key?(state, :root_path)
      assert Map.has_key?(state, :agent)
      assert Map.has_key?(state, :url)
      assert Map.has_key?(state, :tmux_session)
      assert Map.has_key?(state, :pi_alive)
      assert Map.has_key?(state, :started_at)

      assert state.id == id
      assert state.root_path == root
      assert state.agent == "echo"

      SessionServer.stop(id)
    end

    test "remote session uses /tmp/pair-sessions path", %{tmp_dir: _tmp} do
      # Remote sessions create fresh projects in /tmp/pair-sessions/
      root = "/tmp/pair-sessions/fresh-project-#{:rand.uniform(999)}"
      refute File.exists?(root)

      id = "test-remote-#{:rand.uniform(999)}"
      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Pair.SessionSupervisor,
          {SessionServer, id: id, root_path: root, env: %{}, agent: "echo"}
        )

      assert File.dir?(root)
      SessionServer.stop(id)
    end
  end

  describe "session idempotency" do
    test "starting same session id twice returns already_started", %{tmp_dir: tmp} do
      root = Path.join(tmp, "idempotent-test")
      File.mkdir_p!(root)
      id = "test-idem-#{:rand.uniform(999)}"

      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Pair.SessionSupervisor,
          {SessionServer, id: id, root_path: root, env: %{}, agent: "echo"}
        )

      result =
        DynamicSupervisor.start_child(
          Pair.SessionSupervisor,
          {SessionServer, id: id, root_path: root, env: %{}, agent: "echo"}
        )

      assert {:error, {:already_started, _}} = result
      SessionServer.stop(id)
    end
  end
end
