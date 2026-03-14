defmodule Jido.SimpleMem.SQLiteStoreTest do
  use ExUnit.Case, async: false

  alias Jido.SimpleMem.{MemoryUnit, Store.SQLite}

  setup do
    path =
      Path.join(System.tmp_dir!(), "jido_simplemem_#{System.unique_integer([:positive])}.sqlite3")

    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "ensure_ready provisions a local sqlite database", %{path: path} do
    assert :ok = SQLite.ensure_ready(path: path)
    assert File.exists?(path)
  end

  test "put/get/list/search work against local sqlite", %{path: path} do
    assert :ok = SQLite.ensure_ready(path: path)

    {:ok, unit} =
      MemoryUnit.new(%{
        id: "smem_local_1",
        namespace: "agent:test",
        restatement: "Alice prefers concise answers.",
        original_text: "Alice prefers concise answers",
        class: :semantic,
        kind: :preference,
        tags: ["persona:style"],
        observed_at: 1_710_000_000_000,
        persons: ["Alice"],
        topic: "response style",
        keywords: ["alice", "prefers", "concise", "answers"],
        content: %{"source" => "chat"},
        metadata: %{"channel" => "chat"},
        embedding: List.duplicate(0.25, 32)
      })

    assert {:ok, ^unit} = SQLite.put(unit, path: path)
    assert {:ok, fetched} = SQLite.get({"agent:test", "smem_local_1"}, path: path)
    assert fetched.id == unit.id

    assert {:ok, units} = SQLite.list("agent:test", path: path)
    assert Enum.any?(units, &(&1.id == unit.id))

    plan = %{
      question: "What does Alice prefer?",
      keywords: ["alice", "prefer", "concise"],
      persons: ["Alice"],
      entities: [],
      location: nil,
      timestamp_hint: nil,
      classes: [],
      kinds: [],
      tags_any: [],
      tags_all: [],
      since: nil,
      until: nil,
      limit: 5,
      query_embedding: List.duplicate(0.25, 32),
      now: 1_710_000_000_000
    }

    assert {:ok, candidates} = SQLite.search("agent:test", plan, path: path)
    candidate = Enum.find(candidates, &(&1.unit.id == unit.id))
    assert candidate.lexical_score > 0.0
    assert candidate.semantic_score > 0.0
    assert candidate.symbolic_score > 0.0
  end
end
