defmodule Jido.SimpleMem.Config do
  @moduledoc false

  alias Jido.SimpleMem.EmbeddingClient.ReqLLM
  alias Jido.SimpleMem.LLMClient.ReqLLM, as: ReqLLMLLM
  alias Jido.SimpleMem.Store.Lance

  @plugin_state_key :__simplemem__

  @spec defaults() :: map()
  def defaults do
    %{
      namespace: nil,
      store: default_store(),
      llm_client: ReqLLMLLM,
      llm_client_opts: default_llm_client_opts(),
      embedding_client: ReqLLM,
      embedding_client_opts: default_embedding_client_opts(),
      retrieval_limit: 10,
      context_token_budget: 1_200,
      window_size: 6,
      overlap_size: 2,
      enable_parallel_processing: true,
      max_parallel_workers: 4,
      enable_parallel_retrieval: true,
      max_retrieval_workers: 4,
      enable_planning: true,
      reflection_enabled: true,
      max_reflection_rounds: 2
    }
  end

  @spec plugin_state_key() :: atom()
  def plugin_state_key, do: @plugin_state_key

  @spec normalize_store(module() | {module(), keyword()} | nil) ::
          {:ok, {module(), keyword()}} | {:error, term()}
  def normalize_store({mod, opts}) when is_atom(mod) and is_list(opts), do: {:ok, {mod, opts}}
  def normalize_store(mod) when is_atom(mod), do: {:ok, {mod, []}}
  def normalize_store(nil), do: {:error, :missing_store}
  def normalize_store(other), do: {:error, {:invalid_store, other}}

  @spec default_store() :: {module(), keyword()}
  def default_store do
    {Lance, [path: lance_path()] ++ default_worker_opts()}
  end

  @spec lance_path() :: String.t()
  def lance_path do
    case System.get_env("JIDO_SIMPLEMEM_LANCE_PATH") do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        Path.expand(".jido/simplemem.lance", File.cwd!())
    end
  end

  @spec default_embedding_client_opts() :: keyword()
  def default_embedding_client_opts do
    model = gateway_model_spec(System.get_env("JIDO_SIMPLEMEM_EMBEDDING_MODEL"))

    []
    |> maybe_put(:model, model)
    |> maybe_put(:api_key, gateway_api_key())
    |> maybe_put(:receive_timeout, gateway_receive_timeout())
    |> maybe_put(:req_http_options, gateway_req_http_options())
  end

  @spec default_llm_client_opts() :: keyword()
  def default_llm_client_opts do
    shared_model = System.get_env("JIDO_SIMPLEMEM_LLM_MODEL")
    extraction_model = System.get_env("JIDO_SIMPLEMEM_EXTRACTION_MODEL") || shared_model
    synthesis_model = System.get_env("JIDO_SIMPLEMEM_SYNTHESIS_MODEL") || shared_model
    planning_model = System.get_env("JIDO_SIMPLEMEM_PLANNING_MODEL") || shared_model
    answer_model = System.get_env("JIDO_SIMPLEMEM_ANSWER_MODEL") || shared_model

    []
    |> maybe_put(:model, gateway_model_spec(shared_model))
    |> maybe_put(:extraction_model, gateway_model_spec(extraction_model))
    |> maybe_put(:synthesis_model, gateway_model_spec(synthesis_model))
    |> maybe_put(:planning_model, gateway_model_spec(planning_model))
    |> maybe_put(:answer_model, gateway_model_spec(answer_model))
    |> maybe_put(:api_key, gateway_api_key())
    |> maybe_put(:receive_timeout, gateway_receive_timeout())
    |> maybe_put(:req_http_options, gateway_req_http_options())
  end

  @spec default_worker_opts() :: keyword()
  def default_worker_opts do
    []
    |> maybe_put(:uv_executable, System.get_env("JIDO_SIMPLEMEM_UV_EXECUTABLE"))
    |> maybe_put(:python_executable, System.get_env("JIDO_SIMPLEMEM_PYTHON_EXECUTABLE"))
    |> maybe_put_integer(
      :worker_start_timeout_ms,
      System.get_env("JIDO_SIMPLEMEM_WORKER_START_TIMEOUT_MS")
    )
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_integer(opts, _key, nil), do: opts
  defp maybe_put_integer(opts, _key, ""), do: opts

  defp maybe_put_integer(opts, key, value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> Keyword.put(opts, key, parsed)
      _ -> opts
    end
  end

  defp gateway_model_spec(nil), do: nil
  defp gateway_model_spec(""), do: nil

  defp gateway_model_spec(model_id) when is_binary(model_id) do
    case gateway_base_url() do
      nil ->
        model_id

      base_url ->
        %{
          provider: :openai,
          id: model_id,
          base_url: base_url
        }
    end
  end

  defp gateway_api_key do
    case System.get_env("AI_GATEWAY_API_KEY") || System.get_env("VERCEL_API_KEY") do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp gateway_base_url do
    case System.get_env("JIDO_SIMPLEMEM_GATEWAY_BASE_URL") do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp gateway_receive_timeout do
    case gateway_base_url() do
      nil -> nil
      _ -> timeout_env("JIDO_SIMPLEMEM_GATEWAY_RECEIVE_TIMEOUT_MS", 300_000)
    end
  end

  defp gateway_req_http_options do
    case gateway_base_url() do
      nil ->
        nil

      _ ->
        [
          pool_timeout: timeout_env("JIDO_SIMPLEMEM_GATEWAY_POOL_TIMEOUT_MS", 300_000),
          connect_options: [timeout: timeout_env("JIDO_SIMPLEMEM_GATEWAY_CONNECT_TIMEOUT_MS", 60_000)]
        ]
    end
  end

  defp timeout_env(env_var, default) do
    case System.get_env(env_var) do
      value when is_binary(value) and value != "" ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end
end
