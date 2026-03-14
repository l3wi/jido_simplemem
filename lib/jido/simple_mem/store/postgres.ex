defmodule Jido.SimpleMem.Store.Postgres do
  @moduledoc """
  Postgres-backed storage for SimpleMem units.

  The adapter provisions a pgvector-ready schema, but ranking is currently
  computed in Elixir after loading candidate rows for the active namespace.
  """

  @behaviour Jido.SimpleMem.Store

  alias Jido.SimpleMem.MemoryUnit
  alias Jido.SimpleMem.Store.InMemory

  @default_table "simplemem_units"

  @impl true
  def ensure_ready(opts) do
    with {:ok, conn} <- connection(opts),
         {:ok, _} <- query(conn, "CREATE EXTENSION IF NOT EXISTS vector", []),
         {:ok, _} <-
           query(
             conn,
             """
             CREATE TABLE IF NOT EXISTS #{table(opts)} (
               namespace text NOT NULL,
               id text PRIMARY KEY,
               restatement text NOT NULL,
               original_text text,
               class text NOT NULL,
               kind text NOT NULL,
               tags text[] NOT NULL DEFAULT '{}',
               source text,
               observed_at bigint NOT NULL,
               expires_at bigint,
               timestamp text,
               persons text[] NOT NULL DEFAULT '{}',
               entities text[] NOT NULL DEFAULT '{}',
               location text,
               topic text,
               keywords text[] NOT NULL DEFAULT '{}',
               content jsonb NOT NULL DEFAULT '{}'::jsonb,
               metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
               embedding jsonb NOT NULL DEFAULT '[]'::jsonb
             )
             """,
             []
           ) do
      GenServer.stop(conn)
      :ok
    end
  end

  @impl true
  def put(%MemoryUnit{} = unit, opts) do
    with {:ok, conn} <- connection(opts),
         {:ok, _} <-
           query(
             conn,
             """
             INSERT INTO #{table(opts)} (
               namespace, id, restatement, original_text, class, kind, tags, source, observed_at,
               expires_at, timestamp, persons, entities, location, topic, keywords, content, metadata, embedding
             )
             VALUES (
               $1, $2, $3, $4, $5, $6, $7, $8, $9,
               $10, $11, $12, $13, $14, $15, $16, $17::jsonb, $18::jsonb, $19::jsonb
             )
             ON CONFLICT (id) DO UPDATE SET
               namespace = EXCLUDED.namespace,
               restatement = EXCLUDED.restatement,
               original_text = EXCLUDED.original_text,
               class = EXCLUDED.class,
               kind = EXCLUDED.kind,
               tags = EXCLUDED.tags,
               source = EXCLUDED.source,
               observed_at = EXCLUDED.observed_at,
               expires_at = EXCLUDED.expires_at,
               timestamp = EXCLUDED.timestamp,
               persons = EXCLUDED.persons,
               entities = EXCLUDED.entities,
               location = EXCLUDED.location,
               topic = EXCLUDED.topic,
               keywords = EXCLUDED.keywords,
               content = EXCLUDED.content,
               metadata = EXCLUDED.metadata,
               embedding = EXCLUDED.embedding
             """,
             params(unit)
           ) do
      GenServer.stop(conn)
      {:ok, unit}
    end
  end

  @impl true
  def get({namespace, id}, opts) do
    with {:ok, conn} <- connection(opts),
         {:ok, result} <-
           query(
             conn,
             "SELECT * FROM #{table(opts)} WHERE namespace = $1 AND id = $2 LIMIT 1",
             [namespace, id]
           ) do
      GenServer.stop(conn)

      case result.rows do
        [row] -> {:ok, row_to_unit(result.columns, row)}
        _ -> :not_found
      end
    end
  end

  @impl true
  def delete({namespace, id}, opts) do
    with {:ok, conn} <- connection(opts),
         {:ok, _} <-
           query(conn, "DELETE FROM #{table(opts)} WHERE namespace = $1 AND id = $2", [
             namespace,
             id
           ]) do
      GenServer.stop(conn)
      :ok
    end
  end

  @impl true
  def list(namespace, opts) do
    with {:ok, conn} <- connection(opts),
         {:ok, result} <-
           query(conn, "SELECT * FROM #{table(opts)} WHERE namespace = $1", [namespace]) do
      GenServer.stop(conn)
      {:ok, Enum.map(result.rows, &row_to_unit(result.columns, &1))}
    end
  end

  @impl true
  def search(namespace, plan, opts) do
    with {:ok, units} <- list(namespace, opts) do
      tmp = String.to_atom("jido_simplemem_pg_tmp_#{System.unique_integer([:positive])}")
      :ok = InMemory.ensure_ready(table: tmp)
      Enum.each(units, fn unit -> {:ok, _} = InMemory.put(unit, table: tmp) end)
      result = InMemory.search(namespace, plan, table: tmp)
      :ets.delete(tmp)
      result
    end
  end

  defp connection(opts) do
    Postgrex.start_link(Keyword.drop(opts, [:table]))
  end

  defp table(opts), do: Keyword.get(opts, :table, @default_table)

  defp query(conn, sql, params), do: Postgrex.query(conn, sql, params)

  defp params(unit) do
    [
      unit.namespace,
      unit.id,
      unit.restatement,
      unit.original_text,
      Atom.to_string(unit.class),
      to_string(unit.kind),
      unit.tags,
      unit.source,
      unit.observed_at,
      unit.expires_at,
      unit.timestamp,
      unit.persons,
      unit.entities,
      unit.location,
      unit.topic,
      unit.keywords,
      Jason.encode!(unit.content || %{}),
      Jason.encode!(unit.metadata || %{}),
      Jason.encode!(unit.embedding || [])
    ]
  end

  defp row_to_unit(columns, row) do
    attrs =
      columns
      |> Enum.zip(row)
      |> Map.new()

    {:ok, unit} =
      MemoryUnit.new(%{
        id: attrs["id"],
        namespace: attrs["namespace"],
        restatement: attrs["restatement"],
        original_text: attrs["original_text"],
        class: parse_class(attrs["class"]),
        kind: attrs["kind"],
        tags: attrs["tags"] || [],
        source: attrs["source"],
        observed_at: attrs["observed_at"],
        expires_at: attrs["expires_at"],
        timestamp: attrs["timestamp"],
        persons: attrs["persons"] || [],
        entities: attrs["entities"] || [],
        location: attrs["location"],
        topic: attrs["topic"],
        keywords: attrs["keywords"] || [],
        content: attrs["content"] || %{},
        metadata: attrs["metadata"] || %{},
        embedding: attrs["embedding"] || []
      })

    unit
  end

  defp parse_class("semantic"), do: :semantic
  defp parse_class("procedural"), do: :procedural
  defp parse_class("working"), do: :working
  defp parse_class(_), do: :episodic
end
