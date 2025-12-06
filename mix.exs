defmodule AlCheck.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/LKlemens/al_check"

  def project do
    [
      app: :al_check,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: [
        main_module: CheckEscript,
        path: "scripts/check"
      ],
      description: description(),
      package: package(),
      name: "AlCheck",
      source_url: @source_url,
      docs: docs()
    ]
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
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp description do
    """
    A parallel code quality checker for Elixir projects. Runs format, compile,
    credo, dialyzer, and tests concurrently with smart test partitioning.
    """
  end

  defp package do
    [
      name: "al_check",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      maintainers: ["Klemens Lukaszczyk"],
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "LICENSE"],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
