defmodule Jido.SimpleMem.ConfusableFixtureE2ETest do
  use ExUnit.Case, async: false

  alias Jido.SimpleMem.Store.SQLite
  alias Jido.SimpleMem.TestSupport.ConfusablePeopleFixture

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "jido_simplemem_fixture_#{System.unique_integer([:positive])}.sqlite3"
      )

    on_exit(fn -> File.rm(path) end)

    target = %{
      id: "fixture-agent",
      state: %{
        __simplemem__: %{
          namespace: "agent:fixture-agent",
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
      }
    }

    records =
      Enum.map(ConfusablePeopleFixture.dataset(), fn attrs ->
        {:ok, record} = Jido.SimpleMem.remember(target, attrs)
        record
      end)

    %{target: target, records: records}
  end

  test "fixture dataset resolves intentionally confusable people without mixing facts", %{
    target: target
  } do
    Enum.each(ConfusablePeopleFixture.query_expectations(), fn {question, expected_name,
                                                                expected_fact} ->
      assert {:ok, explain} = Jido.SimpleMem.explain(target, question)
      [top | _] = explain.records
      assert top.text =~ expected_name
      assert top.text =~ expected_fact

      assert {:ok, answer} = Jido.SimpleMem.answer(target, question)
      assert answer.answer =~ expected_name
      assert answer.answer =~ expected_fact
    end)
  end

  test "forgeting one confusable record leaves the rest retrievable", %{
    target: target,
    records: records
  } do
    morgan_lee =
      Enum.find(records, fn record ->
        String.contains?(record.text || "", "Morgan Lee")
      end)

    assert {:ok, true} = Jido.SimpleMem.forget(target, morgan_lee.id)

    assert {:ok, deleted_result} = Jido.SimpleMem.retrieve(target, "What does Morgan Lee prefer?")
    refute Enum.any?(deleted_result, &(&1.id == morgan_lee.id))

    assert {:ok, surviving_result} =
             Jido.SimpleMem.retrieve(target, "What does Morgan Reed prefer?")

    assert Enum.any?(surviving_result, &String.contains?(&1.text || "", "Morgan Reed"))
  end
end
