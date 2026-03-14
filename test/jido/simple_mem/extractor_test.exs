defmodule Jido.SimpleMem.ExtractorTest do
  use ExUnit.Case, async: true

  alias Jido.SimpleMem.{Extractor, Store.InMemory}

  defp datetime!(iso8601) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(iso8601)
    datetime
  end

  setup do
    table = String.to_atom("jido_simplemem_extractor_#{System.unique_integer([:positive])}")
    assert :ok = InMemory.ensure_ready(table: table)

    runtime = %{
      namespace: "agent:test",
      store_mod: InMemory,
      store_opts: [table: table],
      llm_client: Jido.SimpleMem.LLMClient.Noop,
      llm_opts: [],
      embedding_client: Jido.SimpleMem.TestSupport.FakeEmbeddingClient,
      embedding_opts: [],
      now: datetime!("2026-03-14T12:00:00Z") |> DateTime.to_unix(:millisecond)
    }

    %{runtime: runtime}
  end

  test "extract anchors relative time and preserves metadata", %{runtime: runtime} do
    assert {:ok, unit} =
             Extractor.extract(
               %{
                 text: "He will meet Alice at Library tomorrow",
                 metadata: %{"channel" => "chat"},
                 persons: ["Bob", "Alice"]
               },
               runtime
             )

    assert unit.timestamp == "2026-03-15T12:00:00Z"
    assert unit.location == "Library"
    assert "Bob" in unit.persons
    assert "Alice" in unit.persons
    assert unit.restatement =~ "2026-03-15T12:00:00Z"
    assert unit.metadata["channel"] == "chat"
    assert length(unit.embedding) == 32
  end
end
