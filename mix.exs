defmodule ConnPool.Mixfile do
  use Mix.Project

  def project do
    [
      app: :conn_pool,
      version: "0.1.0",
      elixir: "~> 1.5",
      start_permanent: Mix.env == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ConnPool.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [{:earmark, "~> 1.1", only: :dev},
     {:agent_map, git: "git@gitlab.com:flomop/multi_agent.git", app: false},
     {:ex_doc, "~> 0.16", only: :dev}]
  end
end
