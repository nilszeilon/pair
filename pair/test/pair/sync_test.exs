defmodule Pair.SyncTest do
  use ExUnit.Case, async: false

  alias Pair.SessionServer

  test "remote session at /tmp/pair-sessions starts with empty directory" do
    # Remote sessions from local: fresh project, no files synced.
    # The user is expected to SSH in and work directly on the server.
    remote_dir = "/tmp/pair-sessions/empty-project-#{:rand.uniform(1_000_000)}"
    File.mkdir_p!(remote_dir)

    id = "remote-test-#{:rand.uniform(999)}"

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        Pair.SessionSupervisor,
        {SessionServer, id: id, root_path: remote_dir, agent: "echo"}
      )

    state = SessionServer.get_state(id)
    assert state.root_path == remote_dir
    assert File.dir?(remote_dir)

    # Directory exists but is empty (no file syncing)
    assert File.ls!(remote_dir) == []

    SessionServer.stop(id)
    File.rm_rf!(remote_dir)
  end

  test "local session uses existing project directory" do
    # Local sessions: agent runs in cwd, files are already there.
    tmp = Path.join(System.tmp_dir!(), "pair-local-project-#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "README.md"), "# My Local Project")
    File.mkdir_p!(Path.join(tmp, "lib"))
    File.write!(Path.join(tmp, "lib/helper.ex"), "defmodule Helper do end")

    id = "local-test-#{:rand.uniform(999)}"

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        Pair.SessionSupervisor,
        {SessionServer, id: id, root_path: tmp, agent: "echo"}
      )

    state = SessionServer.get_state(id)
    assert state.root_path == tmp

    # Files that were already there should still be there
    assert File.exists?(Path.join(tmp, "README.md"))
    assert File.exists?(Path.join(tmp, "lib/helper.ex"))

    SessionServer.stop(id)
    File.rm_rf!(tmp)
  end
end
