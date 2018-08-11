defmodule G.MixProject do
  use Mix.Project

  def project do
    [
      app: :g,
      version: "0.1.0",
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {G.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"},
      {:lace, github: "queer/lace"},
      {:websockex, github: "queer/websockex"},
      {:swarm, "~> 3.0"},
      {:httpoison, "~> 1.0"},
      {:dialyxir, "~> 1.0.0-rc.2", only: [:dev], runtime: false},
      {:q, github: "mewna/q"},
      {:ace, "~> 0.16.7"},
    ]
  end
end
