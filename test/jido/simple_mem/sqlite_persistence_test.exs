defmodule Jido.SimpleMem.SQLitePersistenceTest do
  use ExUnit.Case, async: false

  alias Jido.SimpleMem.Store.SQLite

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "jido_simplemem_persistence_#{System.unique_integer([:positive])}.sqlite3"
      )

    on_exit(fn -> File.rm(path) end)

    state = %{
      namespace: "agent:persistence-agent",
      store: {SQLite, [path: path]},
      store_opts: [path: path],
      llm_client: Jido.SimpleMem.LLMClient.Noop,
      llm_client_opts: [],
      embedding_client: Jido.SimpleMem.TestSupport.FakeEmbeddingClient,
      embedding_client_opts: [],
      retrieval_limit: 5,
      context_token_budget: 1200,
      reflection_enabled: true,
      max_reflection_rounds: 2
    }

    target = %{id: "persistence-agent", state: %{__simplemem__: state}}
    %{path: path, target: target, state: state}
  end

  test "records survive a fresh runtime against the same sqlite file", %{
    target: target,
    state: state
  } do
    assert {:ok, record} =
             Jido.SimpleMem.remember(target, %{
               text: "Jordan Kim lives in Toronto and prefers chai",
               persons: ["Jordan Kim"],
               topic: "profile"
             })

    fresh_target = %{id: "persistence-agent", state: %{__simplemem__: state}}

    assert {:ok, records} = Jido.SimpleMem.retrieve(fresh_target, "What does Jordan Kim prefer?")
    assert Enum.any?(records, &(&1.id == record.id))

    assert {:ok, true} = Jido.SimpleMem.forget(fresh_target, record.id)
    assert {:ok, after_forget} = Jido.SimpleMem.retrieve(fresh_target, "Jordan Kim")
    refute Enum.any?(after_forget, &(&1.id == record.id))
  end
end
