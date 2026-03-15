defmodule Jido.SimpleMem.EmbeddingClient.ReqLLM do
  @moduledoc false

  @behaviour Jido.SimpleMem.EmbeddingClient

  @impl true
  def embed(text, opts \\ []) when is_binary(text) do
    with {:ok, model_spec} <- fetch_model(opts),
         {:ok, model} <- ReqLLM.Embedding.validate_model(model_spec),
         :ok <- ensure_provider_auth(model.provider, opts),
         {:ok, embedding} <- ReqLLM.Embedding.embed(model_spec, text, request_opts(opts)) do
      {:ok, normalize_embedding(embedding)}
    end
  rescue
    error in [ReqLLM.Error.Invalid.Parameter] ->
      {:error, error}
  end

  defp fetch_model(opts) do
    case Keyword.get(opts, :model) do
      model when (is_binary(model) and model != "") or is_map(model) ->
        {:ok, model}

      _ ->
        {:error,
         ReqLLM.Error.Invalid.Parameter.exception(
           parameter:
             "embedding model required via :model option or JIDO_SIMPLEMEM_EMBEDDING_MODEL env var"
         )}
    end
  end

  defp ensure_provider_auth(provider, opts) do
    case Keyword.get(opts, :api_key) do
      value when is_binary(value) and value != "" ->
        :ok

      _ ->
        env_var = ReqLLM.Keys.env_var_name(provider)

        case System.get_env(env_var) do
          value when is_binary(value) and value != "" ->
            :ok

          _ ->
            {:error,
             ReqLLM.Error.Invalid.Parameter.exception(
               parameter: "provider API key required for embeddings via :api_key option or env var: #{env_var}"
             )}
        end
    end
  end

  defp request_opts(opts) do
    opts
    |> Keyword.take([
      :dimensions,
      :encoding_format,
      :user,
      :provider_options,
      :req_http_options,
      :receive_timeout,
      :api_key
    ])
  end

  defp normalize_embedding(values) when is_list(values) do
    Enum.map(values, fn
      value when is_float(value) -> value
      value when is_integer(value) -> value * 1.0
      value -> value |> to_string() |> String.to_float()
    end)
  end
end
