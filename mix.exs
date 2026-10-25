defmodule Q.MixProject do
  use Mix.Project

  @name "Q"
  @version "2.0.0"
  @url "https://github.com/gpedic/ex_q"

  def project do
    [
      app: :ex_q,
      name: @name,
      version: @version,
      elixir: "~> 1.15",
      docs: docs(),
      description: description(),
      source_url: @url,
      package: package(),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.github": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ]
    ]
  end

  defp description do
    """
    Q provides powerful pipeline composition inspired by Ecto.Multi,
    preserving intermediate results for visibility into your pipeline's state, including when a step returns an error.
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
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: :ex_q,
      files: ["lib", "mix.exs", "README*", "CHANGELOG*", "LICENSE*"],
      maintainers: ["Goran Pedić"],
      licenses: ["MIT"],
      links: %{"GitHub" => @url}
    ]
  end

  defp docs() do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @url,
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
      extras: [
        "README.md": [title: "Overview"],
        "CHANGELOG.md": [title: "Changelog"],
        LICENSE: [title: "License"]
      ],
      groups_for_docs: [
        "Writing a pipeline": &(&1[:group] == "Writing a pipeline"),
        "Functional API": &(&1[:group] == "Functional API"),
        "Inspecting a queue": &(&1[:group] == "Inspecting a queue")
      ]
    ]
  end
end
