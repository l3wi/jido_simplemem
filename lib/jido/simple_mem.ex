defmodule Jido.SimpleMem do
  @moduledoc """
  Core SimpleMem-style memory facade for Jido agents.
  """

  alias Jido.Memory.Record

  alias Jido.SimpleMem.{
    Answerer,
    Config,
    Dialogue,
    Explainer,
    JobRunner,
    Mapper,
    MemoryBuilder,
    Planner,
    Retriever
  }

  @type target :: map() | struct()

  @spec plugin_state_key() :: atom()
  def plugin_state_key, do: Config.plugin_state_key()

  @spec add_dialogue(target(), String.t(), String.t(), nil | String.t() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def add_dialogue(target, speaker, content, timestamp_or_opts \\ nil)

  def add_dialogue(target, speaker, content, timestamp_or_opts)
      when is_binary(speaker) and is_binary(content) do
    {timestamp, dialogue_opts} =
      case timestamp_or_opts do
        value when is_binary(value) -> {value, []}
        value when is_list(value) -> {Keyword.get(value, :timestamp), value}
        nil -> {nil, []}
        _ -> {nil, []}
      end

    add_dialogues(
      target,
      [
        %{
          speaker: speaker,
          content: content,
          timestamp: timestamp,
          dialogue_id: Keyword.get(dialogue_opts, :dialogue_id),
          metadata: Keyword.get(dialogue_opts, :metadata, %{})
        }
      ],
      dialogue_opts
    )
  end

  @spec add_dialogues(target(), [map() | Dialogue.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def add_dialogues(target, dialogues, opts \\ [])

  def add_dialogues(target, dialogues, opts) when is_list(dialogues) and is_list(opts) do
    with {:ok, runtime} <- resolve_runtime(target, %{}, opts),
         :ok <- runtime.store_mod.ensure_ready(runtime.store_opts),
         {:ok, normalized_dialogues} <- normalize_dialogues(dialogues) do
      MemoryBuilder.add_dialogues(normalized_dialogues, runtime)
    end
  end

  @spec finalize(target(), keyword()) :: {:ok, map()} | {:error, term()}
  def finalize(target, opts \\ []) when is_list(opts) do
    with {:ok, runtime} <- resolve_runtime(target, %{}, opts),
         :ok <- runtime.store_mod.ensure_ready(runtime.store_opts) do
      MemoryBuilder.finalize(runtime)
    end
  end

  @spec ask(target(), map() | keyword() | String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def ask(target, question, opts \\ [])

  def ask(target, question, opts) when is_binary(question),
    do: ask(target, %{question: question}, opts)

  def ask(target, question, opts) when is_list(question),
    do: ask(target, Map.new(question), opts)

  def ask(target, question, opts) when is_map(question) and is_list(opts) do
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

  def ask(_target, _question, _opts), do: {:error, :invalid_question}

  @spec get_all_memories(target(), keyword()) :: {:ok, [Record.t()]} | {:error, term()}
  def get_all_memories(target, opts \\ []) when is_list(opts) do
    with {:ok, runtime} <- resolve_runtime(target, %{}, opts),
         :ok <- runtime.store_mod.ensure_ready(runtime.store_opts),
         {:ok, units} <- runtime.store_mod.list(runtime.namespace, runtime.store_opts) do
      {:ok, Enum.map(units, &Mapper.to_record/1)}
    end
  end

  @spec delete_memory(target(), String.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def delete_memory(target, id, opts \\ [])

  def delete_memory(target, id, opts) when is_binary(id) and is_list(opts) do
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

  def delete_memory(_target, _id, _opts), do: {:error, :invalid_id}

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
         {:ok, retrieval} <- Retriever.retrieve(plan, runtime),
         {:ok, selected} <- Retriever.select(retrieval, plan, runtime) do
      records = Enum.map(selected.selected, &Mapper.to_record(&1.unit))

      {:ok,
       Explainer.explain(%{
         query: query,
         plan: plan,
         runtime: runtime,
         ranked: selected,
         retrieval: retrieval,
         records: records
       })}
    end
  end

  def explain(_target, _query, _opts), do: {:error, :invalid_query}

  @spec enqueue_add_dialogues(target(), [map() | Dialogue.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def enqueue_add_dialogues(target, dialogues, opts \\ []) when is_list(dialogues) and is_list(opts) do
    JobRunner.enqueue(
      :post_turn,
      fn -> add_dialogues(target, dialogues, opts) end,
      %{session_id: Keyword.get(opts, :session_id), dialogue_count: length(dialogues)}
    )
  end

  @spec enqueue_finalize(target(), keyword()) :: {:ok, map()} | {:error, term()}
  def enqueue_finalize(target, opts \\ []) when is_list(opts) do
    JobRunner.enqueue(
      :finalize,
      fn -> finalize(target, opts) end,
      %{session_id: Keyword.get(opts, :session_id)}
    )
  end

  @spec await_job(String.t(), timeout()) :: {:ok, term()} | {:error, term()}
  def await_job(job_id, timeout \\ 30_000) when is_binary(job_id) do
    JobRunner.await(job_id, timeout)
  end

  @spec job_status(String.t()) :: {:ok, map()} | :not_found
  def job_status(job_id) when is_binary(job_id) do
    JobRunner.status(job_id)
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
         window_size: window_size,
         overlap_size: overlap_size,
         step_size: max(1, window_size - overlap_size),
         enable_parallel_processing:
           pick_value(
             opts,
             attrs,
             :enable_parallel_processing,
             plugin_state[:enable_parallel_processing] || defaults.enable_parallel_processing
           ),
         max_parallel_workers:
           pick_value(
             opts,
             attrs,
             :max_parallel_workers,
             plugin_state[:max_parallel_workers] || defaults.max_parallel_workers
           ),
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
         enable_planning:
           pick_value(
             opts,
             attrs,
             :enable_planning,
             plugin_state[:enable_planning] || defaults.enable_planning
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

  @spec normalize_dialogues([map() | Dialogue.t()]) :: {:ok, [Dialogue.t()]} | {:error, term()}
  def normalize_dialogues(dialogues) do
    results =
      Enum.map(dialogues, fn
        %Dialogue{} = dialogue -> {:ok, dialogue}
        %{} = attrs -> Dialogue.new(attrs)
        attrs when is_list(attrs) -> Dialogue.new(Map.new(attrs))
        _ -> {:error, :invalid_dialogue}
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      {:error, reason} -> {:error, reason}
      nil -> {:ok, Enum.map(results, fn {:ok, dialogue} -> dialogue end)}
    end
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

  defp plugin_state(%{state: %{} = state}), do: Map.get(state, plugin_state_key(), %{})
  defp plugin_state(%{} = target), do: Map.get(target, plugin_state_key(), %{})
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
