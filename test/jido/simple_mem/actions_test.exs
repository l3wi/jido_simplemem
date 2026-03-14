defmodule Jido.SimpleMem.ActionsTest do
  use ExUnit.Case, async: true

  alias Jido.SimpleMem.Actions.{Answer, Forget, Remember, Retrieve}
  alias Jido.SimpleMem.Store.InMemory

  setup do
    table = String.to_atom("jido_simplemem_actions_#{System.unique_integer([:positive])}")
    assert :ok = InMemory.ensure_ready(table: table)

    target = %{
      id: "actions-agent",
      state: %{
        __simplemem__: %{
          namespace: "agent:actions-agent",
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

    %{target: target}
  end

  test "remember/retrieve/answer/forget actions run end-to-end", %{target: target} do
    assert {:ok, %{last_memory_id: record_id}} =
             Remember.run(
               %{
                 text: "Priya Sharma works in Berlin and prefers structured written updates",
                 persons: ["Priya Sharma"],
                 topic: "profile"
               },
               target
             )

    assert {:ok, %{records: records}} =
             Retrieve.run(
               %{question: "What does Priya Sharma prefer?", memory_result_key: :records},
               target
             )

    assert Enum.any?(records, &(&1.id == record_id))

    assert {:ok, %{memory_answer: answer, memory_results: answer_records}} =
             Answer.run(%{question: "What does Priya Sharma prefer?"}, target)

    assert answer =~ "Priya Sharma"
    assert answer =~ "structured written updates"
    assert Enum.any?(answer_records, &(&1.id == record_id))

    assert {:ok, %{last_memory_deleted?: true}} = Forget.run(%{id: record_id}, target)

    assert {:ok, %{records: after_forget}} =
             Retrieve.run(%{question: "Priya Sharma", memory_result_key: :records}, target)

    refute Enum.any?(after_forget, &(&1.id == record_id))
  end
end
