defmodule Pair.MixProject do
  use Mix.Project

  def project do
    [
      app: :pair,
      version: "0.3.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Pair.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"}
    ]
  end
end
