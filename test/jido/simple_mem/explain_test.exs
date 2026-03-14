defmodule Jido.SimpleMem.ExplainTest do
  use ExUnit.Case, async: true

  alias Jido.SimpleMem.Store.InMemory

  test "explain returns planner and ranking diagnostics" do
    table = String.to_atom("jido_simplemem_explain_#{System.unique_integer([:positive])}")
    assert :ok = InMemory.ensure_ready(table: table)

    target = %{
      id: "explain-agent",
      state: %{
        __simplemem__: %{
          namespace: "agent:explain-agent",
          store: {InMemory, [table: table]},
          store_opts: [table: table],
          llm_client: Jido.SimpleMem.LLMClient.Noop,
          llm_client_opts: [],
          embedding_client: Jido.SimpleMem.TestSupport.FakeEmbeddingClient,
          embedding_client_opts: []
        }
      }
    }

    {:ok, _} =
      Jido.SimpleMem.remember(target, %{
        text: "Alice discussed launch plans with Bob at HQ",
        persons: ["Alice", "Bob"],
        location: "HQ",
        topic: "launch planning"
      })

    assert {:ok, explain} =
             Jido.SimpleMem.explain(target, %{question: "Where did Alice discuss launch plans?"})

    assert explain.plan.question_type in [:entity, :factual]
    assert is_list(explain.scored_candidates)
    assert is_binary(explain.context_pack)
    assert length(explain.selected_ids) >= 1
  end
end
