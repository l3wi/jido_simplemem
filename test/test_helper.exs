Code.require_file("support/env_loader.ex", __DIR__)
Jido.SimpleMem.TestSupport.EnvLoader.load!()

[
  Path.join(__DIR__, "support/**/*.ex"),
  Path.join(__DIR__, "support/**/*.exs")
]
|> Enum.flat_map(&Path.wildcard/1)
|> Enum.sort()
|> Enum.each(&Code.require_file/1)

ExUnit.start(exclude: [:integration])
