defmodule Jido.SimpleMem.TestSupport.EnvLoader do
  @moduledoc false

  @files [".env.test.local", ".env.test", ".env.local", ".env"]

  def load! do
    Enum.each(@files, &load_file/1)
  end

  defp load_file(path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&skip_line?/1)
      |> Enum.each(&put_env_line/1)
    end
  end

  defp skip_line?(""), do: true
  defp skip_line?(<<"#", _::binary>>), do: true
  defp skip_line?(_line), do: false

  defp put_env_line(line) do
    normalized = String.replace_prefix(line, "export ", "")

    case String.split(normalized, "=", parts: 2) do
      [key, value] ->
        key = String.trim(key)

        if key != "" and System.get_env(key) in [nil, ""] do
          System.put_env(key, strip_quotes(String.trim(value)))
        end

      _ ->
        :ok
    end
  end

  defp strip_quotes(value) do
    value
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
  end
end
