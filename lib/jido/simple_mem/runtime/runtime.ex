defmodule Jido.SimpleMem.Runtime do
  @moduledoc false

  alias Jido.SimpleMem.{Config, EmbeddingVector}

  @default_capture_patterns ["ai.react.query", "ai.llm.response", "ai.tool.result"]

  @spec build_plugin_state(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_plugin_state(agent, config) when is_map(config) do
    defaults = Config.defaults()

    with {:ok, namespace} <- resolve_plugin_namespace(agent, config),
         {:ok, {store_mod, store_opts}} <- resolve_store(%{}, [], config, defaults),
         {:ok, llm_client, llm_opts} <- resolve_client(:llm_client, %{}, [], config, defaults),
         {:ok, embedding_client, embedding_opts} <-
           resolve_client(:embedding_client, %{}, [], config, defaults),
         {:ok, {store_opts, embedding_opts, _embedding_dimensions}} <-
           EmbeddingVector.align(store_opts, embedding_opts) do
      {:ok,
       %{
         namespace: namespace,
         store: {store_mod, store_opts},
         store_opts: store_opts,
         llm_client: llm_client,
         llm_client_opts: llm_opts,
         embedding_client: embedding_client,
         embedding_client_opts: embedding_opts,
         session_id: map_value(config, :session_id, target_id(agent)),
         auto_capture: map_value(config, :auto_capture, true),
         capture_signal_patterns:
           map_value(config, :capture_signal_patterns, @default_capture_patterns),
         window_size: map_value(config, :window_size, defaults.window_size),
         overlap_size: map_value(config, :overlap_size, defaults.overlap_size),
         enable_parallel_retrieval:
           map_value(config, :enable_parallel_retrieval, defaults.enable_parallel_retrieval),
         max_retrieval_workers:
           map_value(config, :max_retrieval_workers, defaults.max_retrieval_workers),
         retrieval_limit: map_value(config, :retrieval_limit, defaults.retrieval_limit),
         context_token_budget:
           map_value(config, :context_token_budget, defaults.context_token_budget),
         tokens_before_finalize:
           map_value(config, :tokens_before_finalize, defaults.tokens_before_finalize),
         reflection_enabled: map_value(config, :reflection_enabled, defaults.reflection_enabled),
         max_reflection_rounds:
           map_value(config, :max_reflection_rounds, defaults.max_reflection_rounds)
       }}
    end
  end

  @spec resolve(map() | struct(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve(target, attrs, opts) when is_map(attrs) and is_list(opts) do
    plugin_state = plugin_state(target)
    defaults = Config.defaults()

    with {:ok, namespace} <-
           resolve_runtime_namespace(target, attrs, opts, plugin_state, defaults),
         {:ok, {store_mod, store_opts}} <- resolve_store(attrs, opts, plugin_state, defaults),
         {:ok, llm_client, llm_opts} <-
           resolve_client(:llm_client, attrs, opts, plugin_state, defaults),
         {:ok, embedding_client, embedding_opts} <-
           resolve_client(:embedding_client, attrs, opts, plugin_state, defaults),
         {:ok, {store_opts, embedding_opts, embedding_dimensions}} <-
           EmbeddingVector.align(store_opts, embedding_opts) do
      window_size =
        pick_value(opts, attrs, :window_size, plugin_state[:window_size] || defaults.window_size)

      overlap_size =
        pick_value(
          opts,
          attrs,
          :overlap_size,
          plugin_state[:overlap_size] || defaults.overlap_size
        )

      {:ok,
       %{
         namespace: namespace,
         session_id:
           pick_value(
             opts,
             attrs,
             :session_id,
             plugin_state[:session_id] || target_id(target) || namespace
           ),
         store_mod: store_mod,
         store_opts: store_opts,
         llm_client: llm_client,
         llm_opts: llm_opts,
         embedding_client: embedding_client,
         embedding_opts: embedding_opts,
         embedding_dimensions: embedding_dimensions,
         retrieval_limit:
           pick_value(
             opts,
             attrs,
             :retrieval_limit,
             plugin_state[:retrieval_limit] || defaults.retrieval_limit
           ),
         context_token_budget:
           pick_value(
             opts,
             attrs,
             :context_token_budget,
             plugin_state[:context_token_budget] || defaults.context_token_budget
           ),
         tokens_before_finalize:
           pick_value(
             opts,
             attrs,
             :tokens_before_finalize,
             plugin_state[:tokens_before_finalize] || defaults.tokens_before_finalize
           ),
         window_size: window_size,
         overlap_size: overlap_size,
         step_size: max(1, window_size - overlap_size),
         enable_parallel_retrieval:
           pick_value(
             opts,
             attrs,
             :enable_parallel_retrieval,
             plugin_state[:enable_parallel_retrieval] || defaults.enable_parallel_retrieval
           ),
         max_retrieval_workers:
           pick_value(
             opts,
             attrs,
             :max_retrieval_workers,
             plugin_state[:max_retrieval_workers] || defaults.max_retrieval_workers
           ),
         reflection_enabled:
           pick_value(
             opts,
             attrs,
             :reflection_enabled,
             plugin_state[:reflection_enabled] || defaults.reflection_enabled
           ),
         max_reflection_rounds:
           pick_value(
             opts,
             attrs,
             :max_reflection_rounds,
             plugin_state[:max_reflection_rounds] || defaults.max_reflection_rounds
           ),
         now: Keyword.get(opts, :now, System.system_time(:millisecond)),
         plugin_state: plugin_state
       }}
    end
  end

  @spec plugin_state(map() | struct()) :: map()
  def plugin_state(%{state: %{} = state}), do: Map.get(state, Config.plugin_state_key(), %{})
  def plugin_state(%{} = target), do: Map.get(target, Config.plugin_state_key(), %{})
  def plugin_state(_), do: %{}

  @spec map_value(map(), atom(), term()) :: term()
  def map_value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  @spec target_id(map() | struct()) :: nil | String.t()
  def target_id(%{id: id}) when is_binary(id), do: id
  def target_id(%{agent: %{id: id}}) when is_binary(id), do: id
  def target_id(_), do: nil

  @spec pick_value(keyword(), map(), atom(), term()) :: term()
  def pick_value(opts, attrs, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> map_value(attrs, key, default)
    end
  end

  defp resolve_plugin_namespace(agent, config) do
    explicit = map_value(config, :namespace)

    cond do
      is_binary(explicit) and String.trim(explicit) != "" ->
        {:ok, String.trim(explicit)}

      map_value(config, :namespace_mode, :per_agent) == :shared ->
        shared = map_value(config, :shared_namespace, "default")
        {:ok, "shared:" <> normalize_shared_namespace(shared)}

      is_binary(target_id(agent)) ->
        {:ok, "agent:" <> target_id(agent)}

      true ->
        {:error, :namespace_required}
    end
  end

  defp resolve_runtime_namespace(target, attrs, opts, plugin_state, defaults) do
    explicit = pick_value(opts, attrs, :namespace, plugin_state[:namespace])

    namespace =
      cond do
        is_binary(explicit) and String.trim(explicit) != "" ->
          String.trim(explicit)

        is_binary(target_id(target)) ->
          "agent:" <> target_id(target)

        defaults.namespace != nil ->
          defaults.namespace

        true ->
          nil
      end

    if is_binary(namespace), do: {:ok, namespace}, else: {:error, :namespace_required}
  end

  defp resolve_store(attrs, opts, source, defaults) do
    store_value = pick_value(opts, attrs, :store, source[:store] || defaults.store)
    override_opts = pick_value(opts, attrs, :store_opts, source[:store_opts] || [])

    with {:ok, {store_mod, base_opts}} <- Config.normalize_store(store_value),
         true <- is_list(override_opts) do
      {:ok, {store_mod, Keyword.merge(base_opts, override_opts)}}
    else
      false -> {:error, :invalid_store_opts}
      {:error, _reason} = error -> error
    end
  end

  defp resolve_client(key, attrs, opts, source, defaults) do
    client = pick_value(opts, attrs, key, source[key] || Map.fetch!(defaults, key))
    client_opts_key = :"#{key}_opts"

    client_opts =
      pick_value(
        opts,
        attrs,
        client_opts_key,
        source[client_opts_key] || Map.get(defaults, client_opts_key, [])
      )

    cond do
      is_atom(client) and not is_nil(client) and is_list(client_opts) ->
        {:ok, client, client_opts}

      not is_atom(client) ->
        {:error, {:invalid_client, key, client}}

      true ->
        {:error, {:invalid_client_opts, client_opts_key}}
    end
  end

  defp normalize_shared_namespace(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: "default", else: trimmed
  end

  defp normalize_shared_namespace(_), do: "default"
end
