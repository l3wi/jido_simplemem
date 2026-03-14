defmodule Jido.SimpleMem.Store.Turso.HttpClient do
  @moduledoc false

  @behaviour Jido.SimpleMem.Store.Turso.Client

  @impl true
  def execute(sql, args, opts) do
    with {:ok, [result]} <- batch([{sql, args}], opts) do
      {:ok, result}
    end
  end

  @impl true
  def batch(statements, opts) do
    payload = %{requests: Enum.map(statements, &request_payload/1)}

    case Req.post(
           url: pipeline_url(opts),
           headers: headers(opts),
           json: payload,
           receive_timeout: Keyword.get(opts, :receive_timeout, 15_000),
           connect_options: Keyword.get(opts, :connect_options, [])
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        decode_results(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_payload({sql, args}) do
    %{
      type: "execute",
      stmt: %{
        sql: sql,
        args: Enum.map(args, &encode_arg/1),
        want_rows: true
      }
    }
  end

  defp headers(opts) do
    base = [{"content-type", "application/json"}]

    case Keyword.get(opts, :auth_token) do
      token when is_binary(token) and token != "" ->
        [{"authorization", "Bearer " <> token} | base]

      _ ->
        base
    end
  end

  defp pipeline_url(opts) do
    explicit = Keyword.get(opts, :pipeline_url)
    database_url = Keyword.get(opts, :url) || Keyword.get(opts, :database_url)

    cond do
      is_binary(explicit) and explicit != "" ->
        explicit

      is_binary(database_url) and String.starts_with?(database_url, "libsql://") ->
        database_url
        |> String.replace_prefix("libsql://", "https://")
        |> append_pipeline_path()

      is_binary(database_url) and String.starts_with?(database_url, "https://") ->
        append_pipeline_path(database_url)

      true ->
        raise ArgumentError, "Turso URL required via :url, :database_url, or :pipeline_url"
    end
  end

  defp append_pipeline_path(url) do
    if String.ends_with?(url, "/v2/pipeline") do
      url
    else
      String.trim_trailing(url, "/") <> "/v2/pipeline"
    end
  end

  defp encode_arg(nil), do: %{type: "null"}

  defp encode_arg(value) when is_boolean(value),
    do: %{type: "integer", value: if(value, do: "1", else: "0")}

  defp encode_arg(value) when is_integer(value),
    do: %{type: "integer", value: Integer.to_string(value)}

  defp encode_arg(value) when is_float(value), do: %{type: "float", value: value}
  defp encode_arg(value) when is_binary(value), do: %{type: "text", value: value}
  defp encode_arg(value), do: %{type: "text", value: to_string(value)}

  defp decode_results(%{"results" => results}) when is_list(results) do
    results
    |> Enum.reduce_while({:ok, []}, fn result, {:ok, acc} ->
      case decode_result(result) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp decode_results(other), do: {:error, {:unexpected_response, other}}

  defp decode_result(%{"type" => "ok", "response" => response}), do: decode_result(response)

  defp decode_result(%{"type" => "error", "error" => error}) do
    {:error, {:remote_error, error}}
  end

  defp decode_result(%{"result" => result}), do: decode_result(result)

  defp decode_result(%{"rows" => rows} = result) when is_list(rows) do
    columns =
      result
      |> Map.get("cols", [])
      |> Enum.map(fn
        %{"name" => name} -> name
        %{"column" => name} -> name
        name when is_binary(name) -> name
      end)

    decoded_rows =
      Enum.map(rows, fn
        row when is_map(row) ->
          row

        values when is_list(values) ->
          columns
          |> Enum.zip(Enum.map(values, &decode_value/1))
          |> Map.new()
      end)

    {:ok,
     %{
       rows: decoded_rows,
       affected_row_count: Map.get(result, "affected_row_count", 0)
     }}
  end

  defp decode_result(other), do: {:error, {:unexpected_result, other}}

  defp decode_value(%{"type" => "null"}), do: nil

  defp decode_value(%{"type" => "integer", "value" => value}) when is_binary(value),
    do: String.to_integer(value)

  defp decode_value(%{"type" => "float", "value" => value}), do: value
  defp decode_value(%{"type" => "text", "value" => value}), do: value
  defp decode_value(%{"type" => "blob", "base64" => value}), do: Base.decode64!(value)
  defp decode_value(%{"value" => value}), do: value
  defp decode_value(value), do: value
end
