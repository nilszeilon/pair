defmodule Pair.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    bind = System.get_env("BIND", "127.0.0.1")
    port = String.to_integer(System.get_env("PAIR_PORT", "4242"))

    children = [
      {Registry, keys: :unique, name: Pair.SessionRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Pair.SessionSupervisor},
      {Bandit, plug: Pair.HTTPServer, scheme: :http, port: port, ip: parse_ip(bind)}
    ]

    IO.puts("""
    🧠 Pair Session orchestrator
       REST API:  http://#{bind}:#{port}
       Sessions:  http://#{bind}:#{port}/

       Default: localhost only. Use BIND=0.0.0.0 for Tailscale access.
    """)

    opts = [strategy: :one_for_one, name: Pair.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp parse_ip(ip) when is_binary(ip) do
    case :inet.parse_strict_address(String.to_charlist(ip)) do
      {:ok, addr} -> addr
      _ -> {127, 0, 0, 1}
    end
  end
end
