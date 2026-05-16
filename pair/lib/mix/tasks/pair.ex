defmodule Mix.Tasks.Pair do
  @moduledoc """
  Starts the Pair session orchestrator.

  Discovers tmux sessions running agents and serves them via ttyd.
  Open http://localhost:4242 to manage sessions in the browser.
  """

  use Mix.Task

  @shortdoc "Start the Pair session orchestrator"

  def run(args) do
    case args do
      ["server" | _] ->
        {:ok, _} = Application.ensure_all_started(:pair)
        bind = System.get_env("BIND", "127.0.0.1")
        port = System.get_env("PAIR_PORT", "4242")
        IO.puts("Pair orchestrator → http://#{bind}:#{port}")
        IO.puts("Open in browser to manage sessions, or POST /sessions via curl.")
        Process.sleep(:infinity)

      _ ->
        IO.puts("Usage: mix pair server")
    end
  end
end
