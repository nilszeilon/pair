defmodule Mix.Tasks.Pair do
  @moduledoc """
  Starts the Pair session orchestrator server.

  The primary CLI is the Go client (`pair`). See pair-client/main.go.
  """

  use Mix.Task

  @shortdoc "Start the Pair orchestrator server"

  def run(args) do
    case args do
      ["server" | _] ->
        {:ok, _} = Application.ensure_all_started(:pair)
        bind = System.get_env("BIND", "127.0.0.1")
        port = System.get_env("PAIR_PORT", "4242")
        IO.puts("Orchestrator running at http://#{bind}:#{port}")
        IO.puts("Use 'pair pi' from another terminal.")
        Process.sleep(:infinity)

      _ ->
        IO.puts("Usage: mix pair server")
        IO.puts("Use the Go client (`pair`) for session management.")
    end
  end
end
