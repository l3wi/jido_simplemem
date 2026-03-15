defmodule Jido.SimpleMem.StrictLLMBehaviorTest do
  use ExUnit.Case, async: true

  alias Jido.SimpleMem
  alias Jido.SimpleMem.TestSupport.{Factory, FakeEmbeddingClient, FakeLLMClient}

  defmodule EmptyExtractionLLMClient do
    @behaviour Jido.SimpleMem.LLMClient

    @impl true
    def extract_window(_dialogues, _previous_entries, _opts), do: {:ok, []}

    @impl true
    def synthesize(entries, _previous_entries, _opts), do: {:ok, entries}

    @impl true
    def plan(query, opts), do: FakeLLMClient.plan(query, opts)

    @impl true
    def reflect(query, records, plan, opts), do: FakeLLMClient.reflect(query, records, plan, opts)

    @impl true
    def answer(question, records, opts), do: FakeLLMClient.answer(question, records, opts)
  end

  defmodule EmptySynthesisLLMClient do
    @behaviour Jido.SimpleMem.LLMClient

    @impl true
    def extract_window(dialogues, previous_entries, opts),
      do: FakeLLMClient.extract_window(dialogues, previous_entries, opts)

    @impl true
    def synthesize(_entries, _previous_entries, _opts), do: {:ok, []}

    @impl true
    def plan(query, opts), do: FakeLLMClient.plan(query, opts)

    @impl true
    def reflect(query, records, plan, opts), do: FakeLLMClient.reflect(query, records, plan, opts)

    @impl true
    def answer(question, records, opts), do: FakeLLMClient.answer(question, records, opts)
  end

  defmodule BlankAnswerLLMClient do
    @behaviour Jido.SimpleMem.LLMClient

    @impl true
    def extract_window(dialogues, previous_entries, opts),
      do: FakeLLMClient.extract_window(dialogues, previous_entries, opts)

    @impl true
    def synthesize(entries, previous_entries, opts),
      do: FakeLLMClient.synthesize(entries, previous_entries, opts)

    @impl true
    def plan(query, opts), do: FakeLLMClient.plan(query, opts)

    @impl true
    def reflect(query, records, plan, opts), do: FakeLLMClient.reflect(query, records, plan, opts)

    @impl true
    def answer(_question, _records, _opts) do
      {:ok, %{answer: "", reasoning: "", confidence: nil, context: ""}}
    end
  end

  test "empty extraction output surfaces as an error instead of silently succeeding" do
    target =
      Factory.target("strict-empty-extraction",
        llm_client: EmptyExtractionLLMClient,
        embedding_client: FakeEmbeddingClient,
        window_size: 2,
        overlap_size: 1
      )

    assert {:error, {:empty_extraction, _}} =
             SimpleMem.add_dialogues(target, [
               %{
                 speaker: "user",
                 content: "Remember this durable fact: Nora Chen lives in Kyoto."
               },
               %{speaker: "assistant", content: "I will remember it."}
             ])
  end

  test "empty synthesis output surfaces as an error instead of silently storing extracted entries" do
    target =
      Factory.target("strict-empty-synthesis",
        llm_client: EmptySynthesisLLMClient,
        embedding_client: FakeEmbeddingClient,
        window_size: 2,
        overlap_size: 1
      )

    assert {:error, {:empty_synthesis, _}} =
             SimpleMem.add_dialogues(target, [
               %{
                 speaker: "user",
                 content: "Remember this durable fact: Nora Chen prefers oolong tea."
               },
               %{speaker: "assistant", content: "I will remember it."}
             ])
  end

  test "blank answer output surfaces as an error instead of degrading to a top-record answer" do
    target =
      Factory.target("strict-blank-answer",
        llm_client: BlankAnswerLLMClient,
        embedding_client: FakeEmbeddingClient,
        window_size: 2,
        overlap_size: 1
      )

    assert {:ok, _} =
             SimpleMem.add_dialogues(target, [
               %{speaker: "user", content: "Mira Patel prefers jasmine tea"},
               %{speaker: "assistant", content: "Noted."}
             ])

    assert {:error, {:invalid_answer, _}} =
             SimpleMem.ask(target, "What does Mira Patel prefer?")
  end
end
