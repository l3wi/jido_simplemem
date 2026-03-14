defmodule Jido.SimpleMem do
  @moduledoc """
  Single-tier SimpleMem-inspired memory facade for Jido agents.
  """

  alias Jido.Memory.Query
  alias Jido.Memory.Record

  alias Jido.SimpleMem.{
    Answerer,
    Config,
    Explainer,
    Extractor,
    Mapper,
    Planner,
    Ranker,
    Retriever,
    Synthesizer
  }

  @type target :: map() | struct()

  @spec plugin_state_key() :: atom()
  def plugin_state_key, do: Config.plugin_state_key()

  @spec remember(target(), map() | keyword(), keyword()) :: {:ok, Record.t()} | {:error, term()}
  def remember(target, attrs, opts \\ [])

  def remember(target, attrs, opts) when is_list(attrs),
    do: remember(target, Map.new(attrs), opts)

  def remember(target, attrs, opts) when is_map(attrs) and is_list(opts) do
    with {:ok, runtime} <- resolve_runtime(target, attrs, opts),
         :ok <- runtime.store_mod.ensure_ready(runtime.store_opts),
         {:ok, unit} <- Extractor.extract(attrs, runtime),
         {:ok, merged} <- Synthesizer.synthesize(unit, runtime),
         {:ok, stored} <- runtime.store_mod.put(merged, runtime.store_opts) do
      {:ok, Mapper.to_record(stored)}
    end
  end

  def remember(_target, _attrs, _opts), do: {:error, :invalid_attrs}

  @spec retrieve(target(), Query.t() | map() | keyword() | String.t(), keyword()) ::
          {:ok, [Record.t()]} | {:error, term()}
  def retrieve(target, query, opts \\ [])

  def retrieve(target, %Query{} = query, opts) do
    retrieve(target, Map.from_struct(query), opts)
  end

  def retrieve(target, query, opts) when is_list(query),
    do: retrieve(target, Map.new(query), opts)

  def retrieve(target, query, opts) when is_binary(query) do
    retrieve(target, %{question: query, text_contains: query}, opts)
  end

  def retrieve(target, query, opts) when is_map(query) and is_list(opts) do
    with {:ok, explain} <- explain(target, query, opts) do
      {:ok, explain.records}
    end
  end

  def retrieve(_target, _query, _opts), do: {:error, :invalid_query}

  @spec answer(target(), map() | keyword() | String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def answer(target, question, opts \\ [])

  def answer(target, question, opts) when is_binary(question),
    do: answer(target, %{question: question}, opts)

  def answer(target, question, opts) when is_list(question),
    do: answer(target, Map.new(question), opts)

  def answer(target, question, opts) when is_map(question) and is_list(opts) do
    with {:ok, explain} <- explain(target, question, opts),
         {:ok, answer} <- Answerer.answer(question, explain, explain.runtime) do
      {:ok,
       %{
         answer: answer.answer,
         confidence: answer.confidence,
         reasoning: answer.reasoning,
         context: answer.context,
         records: explain.records
       }}
    end
  end

  def answer(_target, _question, _opts), do: {:error, :invalid_question}

  @spec forget(target(), String.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def forget(target, id, opts \\ [])

  def forget(target, id, opts) when is_binary(id) and is_list(opts) do
    with {:ok, runtime} <- resolve_runtime(target, %{}, opts),
         :ok <- runtime.store_mod.ensure_ready(runtime.store_opts) do
      case runtime.store_mod.get({runtime.namespace, id}, runtime.store_opts) do
        {:ok, _unit} ->
          :ok = runtime.store_mod.delete({runtime.namespace, id}, runtime.store_opts)
          {:ok, true}

        :not_found ->
          {:ok, false}

        {:error, _reason} = error ->
          error
      end
    end
  end

  def forget(_target, _id, _opts), do: {:error, :invalid_id}

  @spec explain(target(), map() | keyword() | String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def explain(target, query, opts \\ [])

  def explain(target, query, opts) when is_binary(query),
    do: explain(target, %{question: query, text_contains: query}, opts)

  def explain(target, query, opts) when is_list(query),
    do: explain(target, Map.new(query), opts)

  def explain(target, query, opts) when is_map(query) and is_list(opts) do
    with {:ok, runtime} <- resolve_runtime(target, query, opts),
         :ok <- runtime.store_mod.ensure_ready(runtime.store_opts),
         {:ok, plan} <- Planner.plan(query, runtime),
         {:ok, candidates} <- Retriever.retrieve(plan, runtime),
         {:ok, ranked} <- Ranker.rank(candidates, plan, runtime) do
      records = Enum.map(ranked.selected, &Mapper.to_record(&1.unit))

      {:ok,
       Explainer.explain(%{
         query: query,
         plan: plan,
         runtime: runtime,
         ranked: ranked,
         records: records
       })}
    end
  end

  def explain(_target, _query, _opts), do: {:error, :invalid_query}

  @spec resolve_runtime(target(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve_runtime(target, attrs, opts) when is_map(attrs) and is_list(opts) do
    plugin_state = plugin_state(target)
    defaults = Config.defaults()

    with {:ok, namespace} <- resolve_namespace(target, attrs, opts, plugin_state, defaults),
         {:ok, {store_mod, store_opts}} <- resolve_store(attrs, opts, plugin_state, defaults),
         {:ok, llm_client, llm_opts} <-
           resolve_client(:llm_client, attrs, opts, plugin_state, defaults),
         {:ok, embedding_client, embedding_opts} <-
           resolve_client(:embedding_client, attrs, opts, plugin_state, defaults) do
      {:ok,
       %{
         namespace: namespace,
         store_mod: store_mod,
         store_opts: store_opts,
         llm_client: llm_client,
         llm_opts: llm_opts,
         embedding_client: embedding_client,
         embedding_opts: embedding_opts,
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

  @spec build_context([Record.t()], pos_integer()) :: String.t()
  def build_context(records, budget \\ 1_200) do
    records
    |> Enum.map(&("- " <> (&1.text || "")))
    |> Enum.reduce_while({"", 0}, fn line, {acc, size} ->
      next_size = size + String.length(line)

      if next_size > budget do
        {:halt, {acc, size}}
      else
        {:cont, {acc <> line <> "\n", next_size}}
      end
    end)
    |> elem(0)
    |> String.trim()
  end

  defp resolve_namespace(target, attrs, opts, plugin_state, defaults) do
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

  defp resolve_store(attrs, opts, plugin_state, defaults) do
    store_value = pick_value(opts, attrs, :store, plugin_state[:store] || defaults.store)
    override_opts = pick_value(opts, attrs, :store_opts, plugin_state[:store_opts] || [])

    with {:ok, {store_mod, base_opts}} <- Config.normalize_store(store_value),
         true <- is_list(override_opts) do
      {:ok, {store_mod, Keyword.merge(base_opts, override_opts)}}
    else
      false -> {:error, :invalid_store_opts}
      {:error, _reason} = error -> error
    end
  end

  defp resolve_client(key, attrs, opts, plugin_state, defaults) do
    client = pick_value(opts, attrs, key, plugin_state[key] || Map.fetch!(defaults, key))
    client_opts_key = String.to_atom("#{key}_opts")

    client_opts =
      pick_value(
        opts,
        attrs,
        client_opts_key,
        plugin_state[client_opts_key] || Map.get(defaults, client_opts_key, [])
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

  defp plugin_state(%{state: %{} = state}) do
    Map.get(state, plugin_state_key(), %{})
  end

  defp plugin_state(%{} = target) do
    Map.get(target, plugin_state_key(), %{})
  end

  defp plugin_state(_), do: %{}

  defp target_id(%{id: id}) when is_binary(id), do: id
  defp target_id(%{agent: %{id: id}}) when is_binary(id), do: id
  defp target_id(_), do: nil

  defp pick_value(opts, attrs, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
    end
  end
end
