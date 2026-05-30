defmodule JidoWatch.MixProject do
  use Mix.Project

  @version "1.1.0"
  @source_url "https://github.com/elimydlarz/jido_watch"

  def project do
    [
      app: :jido_watch,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs()
    ]
  end

  def cli do
    [
      preferred_envs: [
        "test.domain": :test,
        "test.use_case": :test,
        "test.adapter": :test,
        "test.system": :test,
        "test.journey": :test,
        "test.stale": :test
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:jido, "~> 2.2"},
      {:req, "~> 0.5"},
      {:junit_formatter, "~> 3.3", only: :test},
      {:stream_data, "~> 1.0", only: :test},
      {:plug, "~> 1.16", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      "test.domain": ["test --only domain"],
      "test.use_case": ["test --only use_case"],
      "test.adapter": ["test --only adapter"],
      "test.system": ["test --only system"],
      "test.journey": ["test --only journey"],
      "test.stale": ["test --stale"]
    ]
  end

  defp description do
    "Behaviour and Jido plugin that turns a Jido agent into a viewer: poll a media feed, run new watches through a transcript-chunking pipeline, and produce structured opinions the agent delivers in its own voice."
  end

  defp package do
    [
      organization: "susu",
      maintainers: ["susu-eng"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Issues" => "#{@source_url}/issues"
      },
      files:
        ~w(lib mix.exs README.md CHANGELOG.md CLAUDE.md MENTAL_MODEL.md VISION.md TEST_TREES.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      extras: [
        "README.md",
        "CHANGELOG.md",
        "VISION.md",
        "CLAUDE.md",
        "MENTAL_MODEL.md",
        "TEST_TREES.md"
      ]
    ]
  end
end
