defmodule Jido.SimpleMem.ReflectionTest do
  use ExUnit.Case, async: true

  alias Jido.Memory.Record
  alias Jido.SimpleMem
  alias Jido.SimpleMem.TestSupport.{Factory, FakeEmbeddingClient, FakeLLMClient}

  defmodule ReflectionDrivenLLMClient do
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
           %{"query" => "coffee", "keywords" => ["coffee"], "persons" => [], "entities" => []}
         ],
         "keywords" => ["coffee"],
         "persons" => [],
         "entities" => [],
         "question_type" => "factual"
       }}
    end

    @impl true
    def reflect(%{question: question}, _records, _plan, _opts) do
      already_reflected? = Process.get(:simplemem_reflection_invoked, false)
      Process.put(:simplemem_reflection_invoked, true)

      if already_reflected? do
        {:ok, %{"status" => "complete", "additional_queries" => []}}
      else
        {:ok,
         %{
           "status" => "incomplete",
           "missing_info" => [question],
           "additional_queries" => [
             %{
               "query" => "Alex Carter preference",
               "keywords" => ["alex", "carter", "preference"],
               "persons" => ["Alex Carter"],
               "entities" => []
             }
           ]
         }}
      end
    end

    @impl true
    def answer(%{question: question}, [%Record{text: text} | _], _opts) do
      {:ok,
       %{
         answer: text,
         reasoning: "Selected the top ranked memory for #{question}.",
         confidence: 0.9,
         context: text
       }}
    end

    def answer(_question, [], _opts) do
      {:ok,
       %{
         answer: "No relevant information found",
         reasoning: "No records were retrieved.",
         confidence: 0.0,
         context: ""
       }}
    end
  end

  setup do
    Process.delete(:simplemem_reflection_invoked)

    target =
      Factory.target("reflection-agent",
        llm_client: ReflectionDrivenLLMClient,
        embedding_client: FakeEmbeddingClient,
        window_size: 4,
        overlap_size: 1
      )

    {:ok, _} =
      SimpleMem.add_dialogues(target, [
        %{speaker: "user", content: "Alex Carter prefers tea"},
        %{speaker: "user", content: "Zoe Patel prefers coffee"},
        %{speaker: "assistant", content: "Noted."},
        %{speaker: "user", content: "They both work remotely"}
      ])

    %{target: target}
  end

  test "reflection adds targeted follow-up retrieval that changes the top result", %{
    target: target
  } do
    Process.delete(:simplemem_reflection_invoked)

    assert {:ok, without_reflection} =
             SimpleMem.explain(
               target,
               %{question: "What does Alex Carter prefer?", reflection_enabled: false}
             )

    assert hd(without_reflection.records).text == "Zoe Patel prefers coffee."
    assert without_reflection.decision_trace.query_count == 1

    Process.delete(:simplemem_reflection_invoked)

    assert {:ok, with_reflection} =
             SimpleMem.explain(target, %{question: "What does Alex Carter prefer?"})

    assert hd(with_reflection.records).text == "Alex Carter prefers tea."
    assert with_reflection.decision_trace.query_count == 2
    assert [%{status: "incomplete"} | _] = with_reflection.reflection_rounds
  end

  test "retrieval keeps a broader merged candidate pool than the final selected limit" do
    broad_target =
      Factory.target("broad-candidate-agent",
        llm_client: FakeLLMClient,
        embedding_client: FakeEmbeddingClient,
        window_size: 4,
        overlap_size: 1,
        retrieval_limit: 2,
        reflection_enabled: false
      )

    assert {:ok, _} =
             SimpleMem.add_dialogues(broad_target, [
               %{speaker: "user", content: "Alex Carter prefers tea"},
               %{speaker: "user", content: "Alex Carter prefers green tea in the morning"},
               %{speaker: "user", content: "Alex Carter likes detailed weekly planning"},
               %{speaker: "user", content: "Alex Carter works remotely from Lisbon"}
             ])

    assert {:ok, explained} =
             SimpleMem.explain(broad_target, %{
               question: "What does Alex Carter prefer?",
               reflection_enabled: false,
               limit: 2
             })

    assert length(explained.selected_ids) == 2
    assert length(explained.scored_candidates) > 2
    assert Enum.any?(explained.retrieval_traces, &(&1.candidate_count > 2))
  end
end
