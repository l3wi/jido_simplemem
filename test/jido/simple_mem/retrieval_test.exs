defmodule Jido.SimpleMem.RetrievalTest do
  use ExUnit.Case, async: true

  alias Jido.SimpleMem.Store.InMemory

  setup do
    table = String.to_atom("jido_simplemem_retrieval_#{System.unique_integer([:positive])}")
    assert :ok = InMemory.ensure_ready(table: table)

    target = %{
      id: "retrieval-agent",
      state: %{
        __simplemem__: %{
          namespace: "agent:retrieval-agent",
          store: {InMemory, [table: table]},
          store_opts: [table: table],
          llm_client: Jido.SimpleMem.LLMClient.Noop,
          llm_client_opts: [],
          embedding_client: Jido.SimpleMem.TestSupport.FakeEmbeddingClient,
          embedding_client_opts: [],
          retrieval_limit: 5,
          context_token_budget: 1200,
          reflection_enabled: true,
          max_reflection_rounds: 2
        }
      }
    }

    {:ok, _} =
      Jido.SimpleMem.remember(target, %{
        class: :episodic,
        kind: :meeting,
        text: "Alice will meet Bob at Cafe Central tomorrow",
        persons: ["Alice", "Bob"],
        location: "Cafe Central",
        topic: "meeting"
      })

    {:ok, _} =
      Jido.SimpleMem.remember(target, %{
        class: :semantic,
        kind: :preference,
        text: "Alice prefers concise answers",
        persons: ["Alice"],
        topic: "response style",
        tags: ["persona:style"]
      })

    %{target: target}
  end

  test "retrieve returns ranked Jido.Memory.Record values", %{target: target} do
    assert {:ok, records} = Jido.SimpleMem.retrieve(target, "Where will Alice meet Bob?")
    assert [%Jido.Memory.Record{} | _] = records
    assert Enum.any?(records, &String.contains?(&1.text || "", "Cafe Central"))
  end

  test "answer synthesizes a memory answer", %{target: target} do
    assert {:ok, result} = Jido.SimpleMem.answer(target, "What does Alice prefer?")
    assert result.answer =~ "Alice"
    assert is_list(result.records)
  end
end
