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
    Retriever,
    Runtime
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
  def enqueue_add_dialogues(target, dialogues, opts \\ [])
      when is_list(dialogues) and is_list(opts) do
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
    Runtime.resolve(target, attrs, opts)
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
end
