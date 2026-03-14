defmodule Jido.SimpleMem.NamespaceIsolationReopenTest do
  use ExUnit.Case, async: false

  alias Jido.SimpleMem.Store.SQLite

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "jido_simplemem_namespace_#{System.unique_integer([:positive])}.sqlite3"
      )

    on_exit(fn -> File.rm(path) end)

    alpha = target("agent-alpha", path)
    beta = target("agent-beta", path)

    %{path: path, alpha: alpha, beta: beta}
  end

  test "multiple agent namespaces remain isolated across reopen", %{
    path: path,
    alpha: alpha,
    beta: beta
  } do
    assert {:ok, alpha_record} =
             Jido.SimpleMem.remember(alpha, %{
               text: "Sam Carter lives in Lisbon and prefers espresso",
               persons: ["Sam Carter"],
               topic: "profile"
             })

    assert {:ok, beta_record} =
             Jido.SimpleMem.remember(beta, %{
               text: "Sam Carter lives in Oslo and prefers herbal tea",
               persons: ["Sam Carter"],
               topic: "profile"
             })

    assert {:ok, alpha_records} = Jido.SimpleMem.retrieve(alpha, "Where does Sam Carter live?")
    assert Enum.any?(alpha_records, &(&1.id == alpha_record.id))
    refute Enum.any?(alpha_records, &(&1.id == beta_record.id))

    assert {:ok, beta_records} = Jido.SimpleMem.retrieve(beta, "Where does Sam Carter live?")
    assert Enum.any?(beta_records, &(&1.id == beta_record.id))
    refute Enum.any?(beta_records, &(&1.id == alpha_record.id))

    reopened_alpha = target("agent-alpha", path)
    reopened_beta = target("agent-beta", path)

    assert {:ok, reopened_alpha_records} =
             Jido.SimpleMem.retrieve(reopened_alpha, "What does Sam Carter prefer?")

    assert Enum.any?(reopened_alpha_records, &String.contains?(&1.text || "", "Lisbon"))
    refute Enum.any?(reopened_alpha_records, &String.contains?(&1.text || "", "Oslo"))

    assert {:ok, reopened_beta_records} =
             Jido.SimpleMem.retrieve(reopened_beta, "What does Sam Carter prefer?")

    assert Enum.any?(reopened_beta_records, &String.contains?(&1.text || "", "Oslo"))
    refute Enum.any?(reopened_beta_records, &String.contains?(&1.text || "", "Lisbon"))

    assert {:ok, true} = Jido.SimpleMem.forget(reopened_alpha, alpha_record.id)

    assert {:ok, alpha_after_forget} = Jido.SimpleMem.retrieve(reopened_alpha, "Sam Carter")
    refute Enum.any?(alpha_after_forget, &(&1.id == alpha_record.id))

    assert {:ok, beta_after_forget} = Jido.SimpleMem.retrieve(reopened_beta, "Sam Carter")
    assert Enum.any?(beta_after_forget, &(&1.id == beta_record.id))
  end

  defp target(agent_id, path) do
    state = %{
      namespace: "agent:" <> agent_id,
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

    %{id: agent_id, state: %{__simplemem__: state}}
  end
end
