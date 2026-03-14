["test_support/**/*.ex", "test_support/**/*.exs"]
|> Enum.flat_map(&Path.wildcard/1)
|> Enum.sort()
|> Enum.each(&Code.require_file/1)

ExUnit.start()
