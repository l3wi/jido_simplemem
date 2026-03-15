defmodule Jido.SimpleMem.LanceStoreTest do
  use ExUnit.Case, async: true

  alias Jido.SimpleMem.{MemoryUnit, Store.Lance}
  alias Jido.SimpleMem.TestSupport.FakeLanceClient

  test "put/get/list/delete/search and buffer operations work through the Lance client contract" do
    path = Path.expand(".tmp/store_#{System.unique_integer([:positive])}.lance", File.cwd!())
    opts = [path: path, client: FakeLanceClient]

    assert :ok = Lance.ensure_ready(opts)

    {:ok, unit} =
      MemoryUnit.new(%{
        id: "smem_lance_1",
        namespace: "agent:test",
        restatement: "Alice Johnson prefers espresso in Portland.",
        original_text: "Alice Johnson prefers espresso in Portland",
        class: :semantic,
        kind: :profile,
        observed_at: 1_710_000_000_000,
        timestamp: "2026-03-15T09:00:00Z",
        persons: ["Alice Johnson"],
        location: "Portland",
        topic: "profile",
        keywords: ["alice", "johnson", "espresso", "portland"],
        content: %{"dialogues" => []},
        metadata: %{"session_id" => "agent:test"},
        embedding: List.duplicate(0.2, 8)
      })

    assert {:ok, stored} = Lance.put(unit, opts)
    assert stored.id == "smem_lance_1"

    assert {:ok, fetched} = Lance.get({"agent:test", "smem_lance_1"}, opts)
    assert fetched.restatement == "Alice Johnson prefers espresso in Portland."

    assert {:ok, [listed]} = Lance.list("agent:test", opts)
    assert listed.id == "smem_lance_1"

    assert {:ok, [candidate]} =
             Lance.search(
               "agent:test",
               %{
                 query_embedding: List.duplicate(0.2, 8),
                 keywords: ["alice", "espresso"],
                 persons: ["Alice Johnson"],
                 entities: [],
                 location: "Portland",
                 time_expression: nil,
                 limit: 5
               },
               opts
             )

    assert :structured in candidate.channels
    assert :semantic in candidate.channels
    assert :keyword in candidate.channels

    assert :ok =
             Lance.replace_buffer(
               "agent:test",
               "session-1",
               %{
                 dialogues: [%{"speaker" => "user", "content" => "Remember this"}],
                 recent_entries: [unit],
                 processed_cursor: 1
               },
               opts
             )

    assert {:ok,
            %{
              dialogues: [%{"content" => "Remember this"}],
              recent_entries: [recent],
              processed_cursor: 1
            }} =
             Lance.load_buffer("agent:test", "session-1", opts)

    assert recent.restatement == "Alice Johnson prefers espresso in Portland."

    assert :ok = Lance.delete_buffer("agent:test", "session-1", opts)

    assert {:ok, %{dialogues: [], recent_entries: [], processed_cursor: 0}} =
             Lance.load_buffer("agent:test", "session-1", opts)

    assert :ok = Lance.delete({"agent:test", "smem_lance_1"}, opts)
    assert :not_found = Lance.get({"agent:test", "smem_lance_1"}, opts)
  end
end
