defmodule Jido.SimpleMem.TursoStoreTest do
  use ExUnit.Case, async: true

  alias Jido.SimpleMem.{MemoryUnit, Store.Turso}

  defmodule FakeClient do
    @behaviour Jido.SimpleMem.Store.Turso.Client

    @impl true
    def execute(sql, args, opts) do
      send(opts[:test_pid], {:execute, sql, args})
      opts[:handler].(:execute, sql, args)
    end

    @impl true
    def batch(statements, opts) do
      send(opts[:test_pid], {:batch, statements})
      opts[:handler].(:batch, statements, [])
    end
  end

  defp unit(attrs \\ %{}) do
    {:ok, unit} =
      MemoryUnit.new(
        Map.merge(
          %{
            id: "smem_1",
            namespace: "agent:test",
            restatement: "Alice prefers concise answers.",
            original_text: "Alice prefers concise answers",
            class: :semantic,
            kind: :preference,
            tags: ["persona:style"],
            observed_at: 1_710_000_000_000,
            persons: ["Alice"],
            entities: [],
            location: nil,
            topic: "response style",
            keywords: ["alice", "prefers", "concise", "answers"],
            content: %{"source" => "chat"},
            metadata: %{"channel" => "chat"},
            embedding: List.duplicate(0.25, 32)
          },
          attrs
        )
      )

    unit
  end

  test "ensure_ready provisions table, vector index, FTS index, and triggers" do
    handler = fn
      :batch, statements, [] ->
        {:ok, Enum.map(statements, fn _ -> %{rows: [], affected_row_count: 0} end)}
    end

    assert :ok =
             Turso.ensure_ready(
               url: "https://example.turso.io",
               auth_token: "token",
               client: FakeClient,
               client_opts: [test_pid: self(), handler: handler]
             )

    assert_receive {:batch, statements}
    sql = Enum.map_join(statements, "\n", &elem(&1, 0))
    assert sql =~ "CREATE TABLE IF NOT EXISTS simplemem_units"
    assert sql =~ "CREATE INDEX IF NOT EXISTS simplemem_units_embedding_idx"
    assert sql =~ "CREATE VIRTUAL TABLE IF NOT EXISTS simplemem_units_fts"
    assert sql =~ "CREATE TRIGGER IF NOT EXISTS simplemem_units_ai"
  end

  test "put stores JSON metadata and vector payloads through the client" do
    unit = unit()

    handler = fn
      :execute, sql, args ->
        assert sql =~ "INSERT INTO simplemem_units"
        assert Enum.any?(args, &(&1 == Jason.encode!(unit.tags)))
        assert Enum.any?(args, &(&1 == Jason.encode!(unit.metadata)))
        assert Enum.any?(args, &(&1 == Jason.encode!(unit.embedding)))
        {:ok, %{rows: [], affected_row_count: 1}}
    end

    assert {:ok, ^unit} =
             Turso.put(
               unit,
               url: "https://example.turso.io",
               auth_token: "token",
               client: FakeClient,
               client_opts: [test_pid: self(), handler: handler]
             )

    assert_receive {:execute, sql, _args}
    assert sql =~ "ON CONFLICT(id) DO UPDATE"
  end

  test "search merges lexical, semantic, and symbolic candidates" do
    lexical =
      row_for(unit(%{id: "lexical", restatement: "Alice prefers concise answers."}),
        lexical_score: 0.92
      )

    semantic =
      row_for(unit(%{id: "semantic", restatement: "Alice likes short replies."}),
        semantic_score: 0.81
      )

    symbolic =
      row_for(unit(%{id: "symbolic", restatement: "Alice prefers bullet points."}),
        symbolic_score: 0.75
      )

    handler = fn
      :execute, sql, _args when is_binary(sql) ->
        cond do
          sql =~ "bm25(" ->
            {:ok, %{rows: [lexical], affected_row_count: 0}}

          sql =~ "vector_top_k(" ->
            {:ok, %{rows: [semantic], affected_row_count: 0}}

          sql =~ "symbolic_score" ->
            {:ok, %{rows: [symbolic], affected_row_count: 0}}

          true ->
            flunk("unexpected SQL: #{sql}")
        end
    end

    plan = %{
      question: "What does Alice prefer?",
      keywords: ["alice", "prefer"],
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

    assert {:ok, candidates} =
             Turso.search(
               "agent:test",
               plan,
               url: "https://example.turso.io",
               auth_token: "token",
               client: FakeClient,
               client_opts: [test_pid: self(), handler: handler]
             )

    assert Enum.map(candidates, & &1.unit.id) |> Enum.sort() == [
             "lexical",
             "semantic",
             "symbolic"
           ]

    assert Enum.find(candidates, &(&1.unit.id == "lexical")).lexical_score > 0.9
    assert Enum.find(candidates, &(&1.unit.id == "semantic")).semantic_score > 0.8
    assert Enum.find(candidates, &(&1.unit.id == "symbolic")).symbolic_score > 0.7
  end

  defp row_for(unit, scores) do
    %{
      "id" => unit.id,
      "namespace" => unit.namespace,
      "restatement" => unit.restatement,
      "original_text" => unit.original_text,
      "class" => Atom.to_string(unit.class),
      "kind" => to_string(unit.kind),
      "tags" => Jason.encode!(unit.tags),
      "source" => unit.source,
      "observed_at" => unit.observed_at,
      "expires_at" => unit.expires_at,
      "timestamp" => unit.timestamp,
      "persons" => Jason.encode!(unit.persons),
      "entities" => Jason.encode!(unit.entities),
      "location" => unit.location,
      "topic" => unit.topic,
      "keywords" => Jason.encode!(unit.keywords),
      "search_text" => Enum.join(unit.keywords, " "),
      "content" => Jason.encode!(unit.content),
      "metadata" => Jason.encode!(unit.metadata),
      "embedding_json" => Jason.encode!(unit.embedding),
      "lexical_score" => scores[:lexical_score] || 0.0,
      "semantic_score" => scores[:semantic_score] || 0.0,
      "symbolic_score" => scores[:symbolic_score] || 0.0
    }
  end
end
