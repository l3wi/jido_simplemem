defmodule Mix.Tasks.Release.Audit do
  use Mix.Task

  @shortdoc "Checks whether the package dependency graph is publishable on Hex"

  @moduledoc """
  Verifies that production dependencies are compatible with Hex package
  publishing.
  """

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("loadpaths")

    issues =
      Mix.Dep.load_and_cache()
      |> Enum.filter(&production_dependency?/1)
      |> Enum.flat_map(&dependency_issues/1)

    if issues == [] do
      Mix.shell().info("Hex publish audit passed.")
    else
      Mix.shell().error("Hex publish audit failed:")
      Enum.each(issues, &Mix.shell().error("  - " <> &1))

      Mix.raise("""
      Resolve the publish blockers above before running `mix release.package` or `mix hex.publish`.
      """)
    end
  end

  defp production_dependency?(%Mix.Dep{opts: opts}) do
    case opts[:only] do
      nil -> true
      :prod -> true
      envs when is_list(envs) -> :prod in envs
      _ -> false
    end
  end

  defp dependency_issues(%Mix.Dep{app: app, scm: Hex.SCM, top_level: true, opts: opts}) do
    if opts[:override] do
      [
        "top-level dependency `#{app}` is marked `override: true`; Hex package builds reject overridden deps"
      ]
    else
      []
    end
  end

  defp dependency_issues(%Mix.Dep{app: app, scm: scm, top_level: top_level})
       when scm != Hex.SCM do
    scope = if top_level, do: "top-level", else: "transitive"

    [
      "#{scope} dependency `#{app}` uses #{inspect(scm)}; Hex packages may only depend on Hex packages"
    ]
  end

  defp dependency_issues(_dep), do: []
end
