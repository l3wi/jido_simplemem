defmodule Jido.SimpleMem.EmbeddingClient.ReqLLM do
  @moduledoc false

  @behaviour Jido.SimpleMem.EmbeddingClient

  @impl true
  def embed(text, opts \\ []) when is_binary(text) do
    with {:ok, model_spec} <- fetch_model(opts),
         {:ok, model} <- ReqLLM.Embedding.validate_model(model_spec),
         :ok <- ensure_provider_auth(model.provider, opts),
         {:ok, embedding_result} <-
           ReqLLM.Embedding.embed(
             model_spec,
             text,
             Keyword.put(request_opts(opts), :return_usage, true)
           ) do
      case embedding_result do
        %{embedding: embedding, usage: usage} ->
          maybe_record_usage(model_spec, usage, opts)
          {:ok, normalize_embedding(embedding)}

        embedding ->
          {:ok, normalize_embedding(embedding)}
      end
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
               parameter:
                 "provider API key required for embeddings via :api_key option or env var: #{env_var}"
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
      :api_key
    ])
    |> maybe_put_base_url(Keyword.get(opts, :model))
  end

  # ReqLLM currently ignores inline model base_url for :embedding operations,
  # so forward it explicitly to keep custom endpoint embeddings on the right host.
  defp maybe_put_base_url(request_opts, %{base_url: base_url})
       when is_binary(base_url) and base_url != "" do
    Keyword.put_new(request_opts, :base_url, base_url)
  end

  defp maybe_put_base_url(request_opts, _model), do: request_opts

  defp maybe_record_usage(model_spec, usage, opts) do
    event = %{
      stage: :embedding,
      model: model_label(model_spec),
      usage: usage
    }

    case Keyword.get(opts, :usage_recorder) do
      pid when is_pid(pid) ->
        send(pid, {:simplemem_usage, event})
        :ok

      fun when is_function(fun, 1) ->
        fun.(event)
        :ok

      {module, function} when is_atom(module) and is_atom(function) ->
        apply(module, function, [event])
        :ok

      _ ->
        :ok
    end
  end

  defp model_label(%{provider: provider, id: id}) when is_atom(provider) and is_binary(id),
    do: "#{provider}:#{id}"

  defp model_label(model) when is_binary(model), do: model
  defp model_label(model), do: inspect(model)

  defp normalize_embedding(values) when is_list(values) do
    Enum.map(values, fn
      value when is_float(value) -> value
      value when is_integer(value) -> value * 1.0
      value -> value |> to_string() |> String.to_float()
    end)
  end
end
