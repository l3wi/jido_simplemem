defmodule Jido.SimpleMem.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/l3wi/jido_simplemem"
  @description "Buffered, LLM-first SimpleMem memory plugin and runtime for Jido agents"

  def project do
    [
      app: :jido_simplemem,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: @description,
      name: "Jido SimpleMem",
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Jido.SimpleMem.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format --check-formatted", "cmd env MIX_ENV=test mix test"],
      "release.check": [
        "format --check-formatted",
        "cmd env MIX_ENV=test mix test",
        "docs",
        "release.audit"
      ],
      "release.package": ["release.check", "cmd mix hex.build"]
    ]
  end

  defp docs do
    [
      main: "readme",
      api_reference: false,
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        {"README.md", title: "Home"},
        {"RELEASING.md", title: "Releasing"},
        {"docs/explanations/default-memory-policy.md", title: "Buffered Lifecycle"},
        {"docs/architecture/lance-worker.md", title: "Lance Worker Architecture"},
        {"docs/decisions/ADR-0001-single-tier-simplemem.md", title: "ADR-0001"},
        {"docs/decisions/ADR-0002-simplemem-parity-refactor.md", title: "ADR-0002"},
        {"CHANGELOG.md", title: "Changelog"},
        {"LICENSE", title: "Apache 2.0 License"}
      ],
      groups_for_extras: [
        Guides: [
          "RELEASING.md",
          "docs/explanations/default-memory-policy.md",
          "docs/architecture/lance-worker.md"
        ],
        Decisions: [
          "docs/decisions/ADR-0001-single-tier-simplemem.md",
          "docs/decisions/ADR-0002-simplemem-parity-refactor.md"
        ],
        Project: [
          "CHANGELOG.md",
          "LICENSE"
        ]
      ],
      formatters: ["html"],
      skip_undefined_reference_warnings_on: [
        "CHANGELOG.md",
        "LICENSE"
      ]
    ]
  end

  defp package do
    [
      files: [
        ".formatter.exs",
        "lib",
        "priv",
        "mix.exs",
        "README.md",
        "CHANGELOG.md",
        "RELEASING.md",
        "LICENSE"
      ],
      maintainers: ["l3wi"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/dev/CHANGELOG.md",
        "Upstream SimpleMem" => "https://github.com/aiming-lab/SimpleMem",
        "Jido" => "https://github.com/agentjido/jido"
      }
    ]
  end

  defp deps do
    [
      {:jido, "~> 2.0.0-rc.5"},
      {:jido_action, "~> 2.1"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5.17"},
      {:req_llm, "~> 1.7"},
      {:zoi, "~> 0.17"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end
end
