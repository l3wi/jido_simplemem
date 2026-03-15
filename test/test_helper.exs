Code.require_file("test_support/env_loader.exs")
Jido.SimpleMem.TestSupport.EnvLoader.load!()

["test_support/**/*.ex", "test_support/**/*.exs"]
|> Enum.flat_map(&Path.wildcard/1)
|> Enum.sort()
|> Enum.each(&Code.require_file/1)

ExUnit.start()
