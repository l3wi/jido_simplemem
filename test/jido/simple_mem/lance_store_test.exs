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

  test "real Lance worker preserves explicit schema when the first row has empty lists" do
    if System.find_executable("uv") || System.find_executable("python3") do
      path =
        Path.expand(".tmp/real_store_#{System.unique_integer([:positive])}.lance", File.cwd!())

      opts = [path: path, worker_start_timeout_ms: 120_000, vector_dimensions: 8]

      assert :ok = Lance.ensure_ready(opts)

      {:ok, seed_unit} =
        MemoryUnit.new(%{
          id: "smem_real_1",
          namespace: "agent:real",
          restatement: "A durable memory without extracted list fields yet.",
          original_text: "A durable memory without extracted list fields yet.",
          class: :semantic,
          kind: :memory,
          observed_at: 1_710_000_000_000,
          timestamp: "2026-03-15T09:00:00Z",
          persons: [],
          entities: [],
          keywords: [],
          content: %{"dialogues" => []},
          metadata: %{"session_id" => "agent:real"},
          embedding: List.duplicate(0.1, 8)
        })

      {:ok, richer_unit} =
        MemoryUnit.new(%{
          id: "smem_real_2",
          namespace: "agent:real",
          restatement: "Morgan Lee lives in Denver and prefers pour-over coffee.",
          original_text: "Morgan Lee lives in Denver and prefers pour-over coffee.",
          class: :semantic,
          kind: :profile,
          observed_at: 1_710_000_100_000,
          timestamp: "2026-03-16T09:00:00Z",
          persons: ["Morgan Lee"],
          entities: ["Denver"],
          location: "Denver",
          topic: "profile",
          keywords: ["morgan", "lee", "denver", "coffee"],
          content: %{"dialogues" => []},
          metadata: %{"session_id" => "agent:real"},
          embedding: List.duplicate(0.2, 8)
        })

      assert {:ok, _stored} = Lance.put(seed_unit, opts)
      assert {:ok, stored} = Lance.put(richer_unit, opts)
      assert stored.id == "smem_real_2"

      assert {:ok, listed} = Lance.list("agent:real", opts)
      assert Enum.any?(listed, &(&1.id == "smem_real_2"))
    else
      :ok
    end
  end
end
