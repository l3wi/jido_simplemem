defmodule Jido.SimpleMem.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/agentjido/jido_simplemem"

  def project do
    [
      app: :jido_simplemem,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: "Single-tier SimpleMem-inspired memory plugin for Jido agents",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Jido.SimpleMem.Application, []}
    ]
  end

  defp aliases do
    [
      quality: ["format --check-formatted", "test"]
    ]
  end

  defp deps do
    [
      {:jido, "~> 2.0.0-rc.5"},
      {:jido_action, github: "agentjido/jido_action", branch: "main", override: true},
      {:jido_memory, github: "agentjido/jido_memory", branch: "main"},
      {:exqlite, "~> 0.28"},
      {:postgrex, "~> 0.20"},
      {:req, "~> 0.5.17"},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end
end
