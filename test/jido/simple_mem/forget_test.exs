defmodule Jido.SimpleMem.ForgetTest do
  use ExUnit.Case, async: true

  alias Jido.SimpleMem.Store.InMemory

  setup do
    table = String.to_atom("jido_simplemem_forget_#{System.unique_integer([:positive])}")
    assert :ok = InMemory.ensure_ready(table: table)

    target = %{
      id: "forget-agent",
      state: %{
        __simplemem__: %{
          namespace: "agent:forget-agent",
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

    {:ok, record} =
      Jido.SimpleMem.remember(target, %{
        class: :semantic,
        kind: :preference,
        text: "Nina prefers detailed status updates",
        persons: ["Nina"],
        topic: "communication"
      })

    %{target: target, record: record}
  end

  test "forget removes a remembered record from subsequent retrieval", %{
    target: target,
    record: record
  } do
    assert {:ok, true} = Jido.SimpleMem.forget(target, record.id)
    assert {:ok, records} = Jido.SimpleMem.retrieve(target, "What does Nina prefer?")
    refute Enum.any?(records, &(&1.id == record.id))
  end

  test "forget returns false when the record is missing", %{target: target} do
    assert {:ok, false} = Jido.SimpleMem.forget(target, "smem_missing")
  end
end
