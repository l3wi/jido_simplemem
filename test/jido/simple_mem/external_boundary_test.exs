defmodule Jido.SimpleMem.ExternalBoundaryTest do
  use ExUnit.Case, async: false

  alias Jido.Memory.Record
  alias Jido.SimpleMem
  alias Jido.SimpleMem.Planner
  alias Jido.SimpleMem.Store.Lance
  alias Jido.SimpleMem.TestSupport.{Factory, FakeEmbeddingClient, FakeLLMClient}

  defmodule UnknownExtractionKeyLLMClient do
    @behaviour Jido.SimpleMem.LLMClient

    @impl true
    def extract_window(_dialogues, _previous_entries, opts) do
      unique_key = Keyword.fetch!(opts, :unique_key)

      {:ok,
       [
         %{
           "restatement" => "Morgan Lee prefers pour-over coffee.",
           "keywords" => ["Morgan Lee", "coffee"],
           "timestamp" => "",
           "location" => "",
           "persons" => ["Morgan Lee"],
           "entities" => [],
           "topic" => "profile",
           unique_key => "drop me"
         }
       ]}
    end

    @impl true
    def synthesize(entries, previous_entries, opts),
      do: FakeLLMClient.synthesize(entries, previous_entries, opts)

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

  defmodule UnknownQuestionTypeLLMClient do
    @behaviour Jido.SimpleMem.LLMClient

    @impl true
    def extract_window(dialogues, previous_entries, opts),
      do: FakeLLMClient.extract_window(dialogues, previous_entries, opts)

    @impl true
    def synthesize(entries, previous_entries, opts),
      do: FakeLLMClient.synthesize(entries, previous_entries, opts)

    @impl true
    def plan(%{question: question}, opts) do
      {:ok,
       %{
         "required_info" => [question],
         "search_queries" => [
           %{
             "query" => question,
             "keywords" => [],
             "persons" => [],
             "entities" => [],
             "location" => "",
             "time_expression" => ""
           }
         ],
         "keywords" => [],
         "persons" => [],
         "entities" => [],
         "location" => "",
         "time_expression" => "",
         "question_type" => Keyword.fetch!(opts, :unknown_question_type)
       }}
    end

    @impl true
    def reflect(query, records, plan, opts), do: FakeLLMClient.reflect(query, records, plan, opts)

    @impl true
    def answer(question, records, opts), do: FakeLLMClient.answer(question, records, opts)
  end

  defmodule UnknownChannelClient do
    @behaviour Jido.SimpleMem.Store.Lance.Client

    @impl true
    def ensure_ready(_opts), do: {:ok, :ok}

    @impl true
    def put(_unit, _opts), do: raise("not implemented")

    @impl true
    def get(_namespace, _id, _opts), do: :not_found

    @impl true
    def delete(_namespace, _id, _opts), do: {:ok, :ok}

    @impl true
    def list(_namespace, _opts), do: {:ok, []}

    @impl true
    def search(namespace, _plan, opts) do
      unique_channel = Keyword.fetch!(opts, :unique_channel)

      {:ok,
       [
         %{
           "unit" => %{
             "entry_id" => "candidate-1",
             "namespace" => namespace,
             "lossless_restatement" => "Morgan Lee prefers pour-over coffee.",
             "original_text" => "Morgan Lee prefers pour-over coffee.",
             "content" => %{"dialogues" => []},
             "class" => "semantic",
             "kind" => "memory",
             "tags" => [],
             "observed_at" => 1_710_000_000_000,
             "persons" => ["Morgan Lee"],
             "entities" => [],
             "keywords" => ["Morgan", "coffee"],
             "metadata" => %{},
             "vector" => List.duplicate(0.1, 8)
           },
           "lexical_score" => 0.9,
           "semantic_score" => 0.8,
           "symbolic_score" => 0.7,
           "recency_score" => 0.6,
           "channels" => ["structured", "semantic", "keyword", unique_channel],
           "lexical_rank" => 1,
           "semantic_rank" => 1,
           "structured_rank" => 1
         }
       ]}
    end

    @impl true
    def load_buffer(_namespace, _session_id, _opts), do: {:ok, %{"dialogues" => []}}

    @impl true
    def replace_buffer(_namespace, _session_id, _state, _opts), do: {:ok, :ok}

    @impl true
    def delete_buffer(_namespace, _session_id, _opts), do: {:ok, :ok}
  end

  test "memory ingestion ignores unknown extracted keys without creating atoms" do
    unique_key = "unknown_extract_key_#{System.unique_integer([:positive])}"

    target =
      Factory.target("boundary-ingest",
        llm_client: UnknownExtractionKeyLLMClient,
        llm_client_opts: [unique_key: unique_key],
        window_size: 1,
        overlap_size: 0
      )

    assert {:ok, %{memory_count: 1}} =
             SimpleMem.add_dialogue(
               target,
               "user",
               "Remember Morgan Lee prefers pour-over coffee."
             )

    assert_raise ArgumentError, fn ->
      :erlang.binary_to_existing_atom(unique_key, :utf8)
    end
  end

  test "planner falls back on unknown question types without creating atoms" do
    unknown_question_type = "unknown_question_type_#{System.unique_integer([:positive])}"

    runtime = %{
      llm_client: UnknownQuestionTypeLLMClient,
      llm_opts: [unknown_question_type: unknown_question_type],
      embedding_client: FakeEmbeddingClient,
      embedding_opts: [dimensions: 8],
      retrieval_limit: 5,
      reflection_enabled: true,
      max_reflection_rounds: 2,
      now: System.system_time(:millisecond),
      embedding_dimensions: 8
    }

    assert {:ok, plan} = Planner.plan(%{question: "Where does Morgan Lee live?"}, runtime)

    assert plan.question_type == :factual

    assert_raise ArgumentError, fn ->
      :erlang.binary_to_existing_atom(unknown_question_type, :utf8)
    end
  end

  test "store search ignores unknown channels without creating atoms" do
    unique_channel = "unknown_channel_#{System.unique_integer([:positive])}"

    assert {:ok, [candidate]} =
             Lance.search(
               "agent:test",
               %{
                 query_embedding: List.duplicate(0.1, 8),
                 keywords: ["Morgan"],
                 persons: ["Morgan Lee"],
                 entities: [],
                 location: nil,
                 time_expression: nil,
                 limit: 5
               },
               path: Factory.unique_path("boundary-store"),
               client: UnknownChannelClient,
               unique_channel: unique_channel
             )

    assert candidate.channels == [:structured, :semantic, :keyword]

    assert_raise ArgumentError, fn ->
      :erlang.binary_to_existing_atom(unique_channel, :utf8)
    end
  end
end
