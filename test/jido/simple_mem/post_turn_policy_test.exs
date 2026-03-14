defmodule Jido.SimpleMem.PostTurnPolicyTest do
  use ExUnit.Case, async: true

  alias Jido.SimpleMem.Actions.PostTurn
  alias Jido.SimpleMem.Store.InMemory

  setup do
    table = String.to_atom("jido_simplemem_post_turn_#{System.unique_integer([:positive])}")
    assert :ok = InMemory.ensure_ready(table: table)

    target = %{
      id: "policy-agent",
      state: %{
        __simplemem__: %{
          namespace: "agent:policy-agent",
          store: {InMemory, [table: table]},
          store_opts: [table: table],
          llm_client: Jido.SimpleMem.LLMClient.Noop,
          llm_client_opts: [],
          embedding_client: Jido.SimpleMem.TestSupport.FakeEmbeddingClient,
          embedding_client_opts: [],
          retrieval_limit: 5,
          context_token_budget: 1200,
          reflection_enabled: true,
          max_reflection_rounds: 2,
          memory_policy: Jido.SimpleMem.Policy.default_options()
        }
      }
    }

    %{target: target}
  end

  test "post_turn stores durable user profile and preference facts as separate memories", %{
    target: target
  } do
    assert {:ok, %{memory_ids: memory_ids, memory_count: 2, last_memory_id: last_memory_id}} =
             PostTurn.run(
               %{
                 user_input: "Remember that I live in Portland and I prefer concise answers.",
                 assistant_response: "I'll keep that in mind."
               },
               target
             )

    assert last_memory_id in memory_ids

    assert {:ok, where_answer} = Jido.SimpleMem.answer(target, "Where does the user live?")
    assert where_answer.answer =~ "Portland"

    assert {:ok, preference_answer} =
             Jido.SimpleMem.answer(target, "What does the user prefer?")

    assert preference_answer.answer =~ "concise answers"
  end

  test "post_turn skips ephemeral turns by default", %{target: target} do
    assert {:ok,
            %{
              memory_ids: [],
              memory_count: 0,
              last_memory_id: nil,
              memory_skipped?: true,
              skip_reason: :not_durable
            }} =
             PostTurn.run(
               %{
                 user_input: "What's the weather in Portland today?",
                 assistant_response: "It's sunny."
               },
               target
             )

    assert {:ok, records} = Jido.SimpleMem.retrieve(target, "weather Portland")
    assert records == []
  end
end
