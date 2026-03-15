defmodule Jido.SimpleMem.BufferedLifecycleTest do
  use ExUnit.Case, async: true

  alias Jido.SimpleMem
  alias Jido.SimpleMem.TestSupport.Factory

  defmodule PreviousEntryAwareLLMClient do
    @behaviour Jido.SimpleMem.LLMClient

    alias Jido.Memory.Record
    alias Jido.SimpleMem.TestSupport.FakeLLMClient

    @impl true
    def extract_window(dialogues, previous_entries, opts) do
      send(self(), {:extract_previous_entries, Enum.map(previous_entries, & &1.restatement)})
      FakeLLMClient.extract_window(dialogues, previous_entries, opts)
    end

    @impl true
    def synthesize(entries, previous_entries, opts) do
      FakeLLMClient.synthesize(entries, previous_entries, opts)
    end

    @impl true
    def plan(query, opts), do: FakeLLMClient.plan(query, opts)

    @impl true
    def reflect(query, records, plan, opts), do: FakeLLMClient.reflect(query, records, plan, opts)

    @impl true
    def answer(question, records, opts) when is_list(records) do
      case records do
        [%Record{} | _] -> FakeLLMClient.answer(question, records, opts)
        _ -> FakeLLMClient.answer(question, records, opts)
      end
    end
  end

  defmodule SkipSynthesisLLMClient do
    @behaviour Jido.SimpleMem.LLMClient

    alias Jido.Memory.Record
    alias Jido.SimpleMem.TestSupport.FakeLLMClient

    @impl true
    def extract_window(_dialogues, _previous_entries, _opts) do
      {:ok,
       [
         %{
           restatement: "Morgan Lee lives in Denver and prefers pour-over coffee.",
           persons: ["Morgan Lee"],
           entities: ["pour-over coffee"],
           location: "Denver",
           topic: "profile",
           keywords: ["Morgan Lee", "Denver", "pour-over coffee"],
           timestamp: ""
         },
         %{
           restatement: "Megan Lee lives in Austin and prefers black tea.",
           persons: ["Megan Lee"],
           entities: ["black tea"],
           location: "Austin",
           topic: "profile",
           keywords: ["Megan Lee", "Austin", "black tea"],
           timestamp: ""
         }
       ]}
    end

    @impl true
    def synthesize(_entries, _previous_entries, _opts) do
      flunk("synthesize/3 should be skipped for distinct custom-endpoint entries")
    end

    @impl true
    def plan(query, opts), do: FakeLLMClient.plan(query, opts)

    @impl true
    def reflect(query, records, plan, opts), do: FakeLLMClient.reflect(query, records, plan, opts)

    @impl true
    def answer(question, records, opts) when is_list(records) do
      case records do
        [%Record{} | _] -> FakeLLMClient.answer(question, records, opts)
        _ -> FakeLLMClient.answer(question, records, opts)
      end
    end
  end

  defmodule WrongDimensionEmbeddingClient do
    @behaviour Jido.SimpleMem.EmbeddingClient

    @impl true
    def embed(_text, _opts), do: {:ok, List.duplicate(0.1, 4)}
  end

  test "buffers incomplete turns, flushes on window completion, and finalizes trailing dialogue" do
    target = Factory.target("buffered-agent", window_size: 2, overlap_size: 1)

    assert {:ok, %{memory_count: 0, buffer_remaining: 1}} =
             SimpleMem.add_dialogue(target, "user", "My name is Alice Chen")

    assert {:ok, []} = SimpleMem.get_all_memories(target)

    assert {:ok, %{memory_count: 2, buffer_remaining: 1}} =
             SimpleMem.add_dialogue(target, "user", "I live in Portland")

    assert {:ok, records} = SimpleMem.get_all_memories(target)
    assert Enum.any?(records, &(&1.text == "The user's name is Alice Chen."))
    assert Enum.any?(records, &(&1.text == "The user lives in Portland."))

    assert {:ok, %{memory_count: 0, buffer_remaining: 0, finalized?: true}} =
             SimpleMem.finalize(target)
  end

  test "unfinished buffered dialogue survives reopen because the buffer is store-backed" do
    path = Factory.unique_path("reopen")
    first = Factory.target("reopen-agent", path: path, window_size: 3, overlap_size: 1)

    assert {:ok, %{buffer_remaining: 1}} =
             SimpleMem.add_dialogue(first, "user", "My name is Priya Sharma")

    reopened = Factory.target("reopen-agent", path: path, window_size: 3, overlap_size: 1)

    assert {:ok, %{memory_count: 3, buffer_remaining: 1}} =
             SimpleMem.add_dialogues(reopened, [
               %{speaker: "user", content: "I live in Berlin"},
               %{speaker: "user", content: "I prefer structured updates"}
             ])

    assert {:ok, records} = SimpleMem.get_all_memories(reopened)
    assert Enum.any?(records, &String.contains?(&1.text || "", "Priya Sharma"))
    assert Enum.any?(records, &String.contains?(&1.text || "", "Berlin"))
  end

  test "auto-finalizes when buffered token usage crosses the configured threshold" do
    target =
      Factory.target("threshold-agent",
        window_size: 6,
        overlap_size: 2,
        context_token_budget: 20,
        tokens_before_finalize: 60
      )

    assert {:ok, %{memory_count: 1, buffer_remaining: 0, finalized?: true, auto_finalized?: true}} =
             SimpleMem.add_dialogue(
               target,
               "user",
               "Remember that Morgan Lee prefers pour-over coffee and lives in Denver."
             )

    assert {:ok, records} = SimpleMem.get_all_memories(target)
    assert Enum.any?(records, &String.contains?(&1.text || "", "Morgan Lee"))
    assert Enum.any?(records, &String.contains?(&1.text || "", "Denver"))
  end

  test "reopened sessions reuse persisted previous synthesized entries across finalize boundaries" do
    path = Factory.unique_path("previous_entries")

    first =
      Factory.target("previous-entry-agent",
        path: path,
        llm_client: PreviousEntryAwareLLMClient,
        window_size: 2,
        overlap_size: 1
      )

    assert {:ok, %{memory_count: 2, buffer_remaining: 1}} =
             SimpleMem.add_dialogues(first, [
               %{speaker: "user", content: "Alex Carter prefers green tea"},
               %{speaker: "user", content: "Alex Carter lives in Dublin"},
               %{speaker: "assistant", content: "Noted."}
             ])

    flush_previous_entry_messages()

    reopened =
      Factory.target("previous-entry-agent",
        path: path,
        llm_client: PreviousEntryAwareLLMClient,
        window_size: 2,
        overlap_size: 1
      )

    assert {:ok, %{finalized?: true}} = SimpleMem.finalize(reopened)
    assert_receive {:extract_previous_entries, previous_entries}
    assert Enum.any?(previous_entries, &String.contains?(&1, "Alex Carter prefers green tea"))
  end

  test "skips the synthesis LLM call for clearly distinct entries on custom endpoints" do
    target =
      Factory.target("skip-synthesis-agent",
        llm_client: SkipSynthesisLLMClient,
        llm_client_opts: [
          model: %{
            provider: :openai,
            id: "qwen/qwen3.5-plus-02-15",
            base_url: "https://openrouter.ai/api/v1"
          }
        ],
        window_size: 2,
        overlap_size: 1
      )

    assert {:ok, %{memory_count: 2}} =
             SimpleMem.add_dialogues(target, [
               %{
                 speaker: "user",
                 content: "Remember Morgan Lee lives in Denver and prefers pour-over coffee."
               },
               %{
                 speaker: "user",
                 content: "Remember Megan Lee lives in Austin and prefers black tea."
               }
             ])
  end

  test "fails fast when embeddings do not match the pinned store dimension" do
    target =
      Factory.target("dimension-mismatch-agent",
        embedding_client: WrongDimensionEmbeddingClient,
        embedding_client_opts: [dimensions: 8],
        store_opts: [
          path: Factory.unique_path("dimension_mismatch"),
          client: Jido.SimpleMem.TestSupport.FakeLanceClient,
          vector_dimensions: 8
        ],
        window_size: 1,
        overlap_size: 0
      )

    assert {:error,
            {:invalid_embedding_dimensions, %{expected: 8, actual: 4, stage: :memory_write}}} =
             SimpleMem.add_dialogue(
               target,
               "user",
               "Morgan Lee prefers pour-over coffee."
             )
  end

  defp flush_previous_entry_messages do
    receive do
      {:extract_previous_entries, _entries} -> flush_previous_entry_messages()
    after
      0 -> :ok
    end
  end
end
