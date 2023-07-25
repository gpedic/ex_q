defmodule Q.MixProject do
  use Mix.Project

  @name "ExQ"
  @version "1.1.0"
  @url "https://github.com/gpedic/ex_q"

  def project do
    [
      app: :ex_q,
      name: @name,
      version: @version,
      elixir: "~> 1.10",
      source_url: "https://github.com/gpedic/ex_q",
      docs: docs(),
      description: description(),
      source_url: @url,
      package: package(),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ]
    ]
  end

  defp description do
    """
    ExQ provides a way of queuing the execution of operations and aggregates all returned values similar to `Ecto.Multi`.
    Operations are queued and executed in FIFO order.
    """
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.2", only: :dev, runtime: false},
      {:excoveralls, "~> 0.16", only: :test, runtime: false},
      {:ex_doc, "~> 0.29.0", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: :ex_q,
      files: ["lib", "mix.exs", "README*", "LICENSE*"],
      maintainers: ["Goran Pedić"],
      licenses: ["MIT"],
      links: %{"GitHub" => @url}
    ]
  end

  defp docs() do
    [
      source_ref: "v#{@version}",
      source_url: @url,
      extras: [
        "README.md"
      ]
    ]
  end
end
