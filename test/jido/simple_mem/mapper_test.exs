defmodule Jido.SimpleMem.MapperTest do
  use ExUnit.Case, async: true

  alias Jido.SimpleMem.{Mapper, MemoryUnit}

  test "maps a memory unit into Jido.Memory.Record" do
    {:ok, unit} =
      MemoryUnit.new(%{
        id: "smem_1",
        namespace: "agent:mapper",
        restatement: "Alice likes concise answers.",
        original_text: "Alice likes concise answers",
        class: :semantic,
        kind: :preference,
        tags: ["persona:style"],
        source: "/tests",
        observed_at: 1_710_000_000_000,
        timestamp: "2026-03-14T00:00:00Z",
        persons: ["Alice"],
        entities: [],
        location: nil,
        topic: "answer style",
        keywords: ["alice", "concise", "answers"],
        metadata: %{"tenant" => "test"},
        content: %{raw: "Alice likes concise answers"},
        embedding: [0.1, 0.2]
      })

    record = Mapper.to_record(unit)

    assert record.id == "smem_1"
    assert record.namespace == "agent:mapper"
    assert record.class == :semantic
    assert record.kind == :preference
    assert record.text == "Alice likes concise answers."
    assert record.metadata["tenant"] == "test"
    assert record.metadata["simplemem"]["persons"] == ["Alice"]
    assert record.metadata["simplemem"]["keywords"] == ["alice", "concise", "answers"]
  end
end
