defmodule Jido.SimpleMem.DisambiguationTest do
  use ExUnit.Case, async: true

  alias Jido.SimpleMem.Store.InMemory

  setup do
    table = String.to_atom("jido_simplemem_disambiguation_#{System.unique_integer([:positive])}")
    assert :ok = InMemory.ensure_ready(table: table)

    target = %{
      id: "disambiguation-agent",
      state: %{
        __simplemem__: %{
          namespace: "agent:disambiguation-agent",
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

    memories = [
      %{
        class: :semantic,
        kind: :profile,
        text: "Alice Johnson lives in Portland and prefers espresso",
        persons: ["Alice Johnson"],
        topic: "profile"
      },
      %{
        class: :semantic,
        kind: :profile,
        text: "Alice Smith lives in Austin and prefers green tea",
        persons: ["Alice Smith"],
        topic: "profile"
      },
      %{
        class: :semantic,
        kind: :profile,
        text: "Alicia Stone lives in Portland and prefers pour-over coffee",
        persons: ["Alicia Stone"],
        topic: "profile"
      }
    ]

    Enum.each(memories, fn attrs ->
      assert {:ok, _record} = Jido.SimpleMem.remember(target, attrs)
    end)

    %{target: target}
  end

  test "retrieve keeps similarly described people separated", %{target: target} do
    assert {:ok, explain} = Jido.SimpleMem.explain(target, "Where does Alice Smith live?")

    [top | _] = explain.records
    assert top.text =~ "Alice Smith"
    assert top.text =~ "Austin"
    refute top.text =~ "Alice Johnson"
  end

  test "answer does not mix up similar profiles", %{target: target} do
    assert {:ok, result} = Jido.SimpleMem.answer(target, "What does Alice Johnson prefer?")

    assert result.answer =~ "Alice Johnson"
    assert result.answer =~ "espresso"
    refute result.answer =~ "green tea"
  end
end
