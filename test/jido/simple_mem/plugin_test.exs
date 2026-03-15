defmodule Jido.SimpleMem.PluginTest do
  use ExUnit.Case, async: true

  alias Jido.Memory.Record
  alias Jido.SimpleMem.Plugin
  alias Jido.SimpleMem.TestSupport.{Factory, FakeEmbeddingClient, FakeLLMClient}
  alias Jido.Signal

  defmodule PluginFlowLLMClient do
    @behaviour Jido.SimpleMem.LLMClient

    @impl true
    def extract_window(dialogues, previous_entries, opts),
      do: FakeLLMClient.extract_window(dialogues, previous_entries, opts)

    @impl true
    def synthesize(entries, previous_entries, opts),
      do: FakeLLMClient.synthesize(entries, previous_entries, opts)

    @impl true
    def plan(%{question: question}, _opts) do
      {:ok,
       %{
         "required_info" => [question],
         "search_queries" => [
           %{
             "query" => "Jamie Lee",
             "keywords" => ["jamie", "lee", "jasmine", "tea", "prefer"],
             "persons" => ["Jamie Lee"],
             "entities" => []
           }
         ],
         "keywords" => ["jamie", "lee", "jasmine", "tea", "prefer"],
         "persons" => ["Jamie Lee"],
         "entities" => [],
         "question_type" => "entity"
       }}
    end

    @impl true
    def reflect(_question, _records, _plan, _opts) do
      {:ok, %{"status" => "complete", "additional_queries" => []}}
    end

    @impl true
    def answer(_question, [%Record{text: text} | _], _opts) do
      {:ok,
       %{answer: text, reasoning: "Selected matching record.", confidence: 0.9, context: text}}
    end

    def answer(_question, [], _opts) do
      {:ok,
       %{
         answer: "No relevant information found",
         reasoning: "No records matched.",
         confidence: 0.0,
         context: ""
       }}
    end
  end

  test "signal routes expose only the parity actions" do
    routes = Plugin.signal_routes(%{})

    assert {"pre_turn", Jido.SimpleMem.Actions.PreTurn} in routes
    assert {"post_turn", Jido.SimpleMem.Actions.PostTurn} in routes
    assert {"finalize", Jido.SimpleMem.Actions.Finalize} in routes
    assert {"ask", Jido.SimpleMem.Actions.Ask} in routes
    assert {"get_all_memories", Jido.SimpleMem.Actions.GetAllMemories} in routes
    assert {"delete_memory", Jido.SimpleMem.Actions.DeleteMemory} in routes

    refute Enum.any?(routes, fn {name, _mod} ->
             name in ["remember", "retrieve", "answer", "forget"]
           end)
  end

  test "plugin mount defaults to the Lance store" do
    agent = %{id: "plugin-agent"}
    assert {:ok, state} = Plugin.mount(agent, %{})
    assert {Jido.SimpleMem.Store.Lance, _opts} = state.store
  end

  test "pre_turn/post_turn/finalize and signal auto-capture work with plugin state" do
    target =
      Factory.target("plugin-flow",
        llm_client: PluginFlowLLMClient,
        embedding_client: FakeEmbeddingClient,
        window_size: 2,
        overlap_size: 1
      )

    context = %{agent: target}

    assert {:ok, %{queued?: true, job_id: post_turn_job_id}} =
             Jido.SimpleMem.Actions.PostTurn.run(
               %{user_input: "Jamie Lee prefers jasmine tea", assistant_response: "Noted."},
               context
             )

    assert {:ok, %{status: status}} = Jido.SimpleMem.job_status(post_turn_job_id)
    assert status in [:running, :completed]

    assert {:ok, {:ok, %{memory_count: 1, buffer_remaining: 1}}} =
             Jido.SimpleMem.await_job(post_turn_job_id)

    assert {:ok, %{queued?: true, job_id: finalize_job_id}} =
             Jido.SimpleMem.Actions.Finalize.run(%{}, context)

    assert {:ok,
            {:ok, %{memory_count: 0, buffer_remaining: 0, last_memory_id: nil, memory_ids: []}}} =
             Jido.SimpleMem.await_job(finalize_job_id)

    assert {:ok, %{status: :completed}} = Jido.SimpleMem.job_status(finalize_job_id)

    assert {:ok, memories} = Jido.SimpleMem.get_all_memories(target)
    assert Enum.any?(memories, &String.contains?(&1.text || "", "Jamie Lee prefers jasmine tea"))

    assert {:ok, %{simplemem_context: _context, memory_results: _results, memory_answer: _answer}} =
             Jido.SimpleMem.Actions.PreTurn.run(
               %{user_input: "What does Jamie Lee prefer?"},
               context
             )

    signal =
      %Signal{
        id: "sig-1",
        type: "ai.react.query",
        source: "test",
        data: %{query: "I live in Berlin"}
      }

    assert {:ok, :continue} = Plugin.handle_signal(signal, context)
    assert {:ok, %{memory_count: 1}} = eventually_finalize(context)
  end

  test "post_turn auto-finalizes when buffered token usage crosses the threshold" do
    target =
      Factory.target("plugin-threshold",
        llm_client: PluginFlowLLMClient,
        embedding_client: FakeEmbeddingClient,
        window_size: 6,
        overlap_size: 2,
        context_token_budget: 20,
        tokens_before_finalize: 60
      )

    context = %{agent: target}

    assert {:ok, %{job_id: job_id, queued?: true}} =
             Jido.SimpleMem.Actions.PostTurn.run(
               %{
                 user_input: "Remember that Jamie Lee prefers jasmine tea and lives in Berlin.",
                 assistant_response: "Noted.",
                 await: false
               },
               context
             )

    assert {:ok, {:ok, %{buffer_remaining: 0, finalized?: true, auto_finalized?: true}}} =
             Jido.SimpleMem.await_job(job_id)
  end

  defp eventually_finalize(context, attempts \\ 10)

  defp eventually_finalize(context, attempts) when attempts > 0 do
    case Jido.SimpleMem.Actions.Finalize.run(%{await: true}, context) do
      {:ok, %{memory_count: 1} = result} ->
        {:ok, result}

      _ ->
        Process.sleep(10)
        eventually_finalize(context, attempts - 1)
    end
  end

  defp eventually_finalize(_context, 0), do: {:error, :finalize_timeout}
end
