defmodule Jido.SimpleMem.Store.SQLite do
  @moduledoc """
  Local SQLite-backed storage for SimpleMem units.

  This is the default store. It uses a normal SQLite database file with:

  - FTS5 lexical indexing over restatements and derived search text
  - JSON-backed symbolic filtering for persons, entities, and tags
  - Elixir-side semantic scoring over persisted embeddings
  """

  @behaviour Jido.SimpleMem.Store

  alias Exqlite.Sqlite3
  alias Jido.SimpleMem.MemoryUnit
  alias Jido.SimpleMem.Tokenizer

  @default_path "simplemem.sqlite3"
  @default_table "simplemem_units"
  @default_candidate_limit 25

  @impl true
  def ensure_ready(opts) do
    path = path(opts)
    :ok = ensure_parent_dir(path)

    with {:ok, conn} <- open(path),
         :ok <- execute_script(conn, pragma_sql() <> schema_sql(opts)) do
      Sqlite3.close(conn)
      :ok
    end
  end

  @impl true
  def put(%MemoryUnit{} = unit, opts) do
    sql = """
    INSERT INTO #{table(opts)} (
      id, namespace, restatement, original_text, class, kind, tags, source, observed_at,
      expires_at, timestamp, persons, entities, location, topic, keywords, search_text,
      content, metadata, embedding_json
    )
    VALUES (
      ?, ?, ?, ?, ?, ?, ?, ?, ?,
      ?, ?, ?, ?, ?, ?, ?, ?,
      ?, ?, ?
    )
    ON CONFLICT(id) DO UPDATE SET
      namespace = excluded.namespace,
      restatement = excluded.restatement,
      original_text = excluded.original_text,
      class = excluded.class,
      kind = excluded.kind,
      tags = excluded.tags,
      source = excluded.source,
      observed_at = excluded.observed_at,
      expires_at = excluded.expires_at,
      timestamp = excluded.timestamp,
      persons = excluded.persons,
      entities = excluded.entities,
      location = excluded.location,
      topic = excluded.topic,
      keywords = excluded.keywords,
      search_text = excluded.search_text,
      content = excluded.content,
      metadata = excluded.metadata,
      embedding_json = excluded.embedding_json
    """

    with {:ok, conn} <- open(path(opts)),
         {:ok, _} <- execute(conn, sql, put_args(unit)) do
      Sqlite3.close(conn)
      {:ok, unit}
    end
  end

  @impl true
  def get({namespace, id}, opts) do
    sql = """
    SELECT * FROM #{table(opts)}
    WHERE namespace = ? AND id = ?
    LIMIT 1
    """

    with {:ok, conn} <- open(path(opts)),
         {:ok, rows} <- query(conn, sql, [namespace, id]) do
      Sqlite3.close(conn)

      case rows do
        [row | _] -> {:ok, row_to_unit(row)}
        [] -> :not_found
      end
    end
  end

  @impl true
  def delete({namespace, id}, opts) do
    sql = "DELETE FROM #{table(opts)} WHERE namespace = ? AND id = ?"

    with {:ok, conn} <- open(path(opts)),
         {:ok, _} <- execute(conn, sql, [namespace, id]) do
      Sqlite3.close(conn)
      :ok
    end
  end

  @impl true
  def list(namespace, opts) do
    sql = """
    SELECT * FROM #{table(opts)}
    WHERE namespace = ?
    ORDER BY observed_at DESC
    """

    with {:ok, conn} <- open(path(opts)),
         {:ok, rows} <- query(conn, sql, [namespace]) do
      Sqlite3.close(conn)
      {:ok, Enum.map(rows, &row_to_unit/1)}
    end
  end

  @impl true
  def search(namespace, plan, opts) do
    limit = max((plan.limit || 10) * 3, @default_candidate_limit)

    with {:ok, lexical_rows} <- lexical_search(namespace, plan, limit, opts),
         {:ok, symbolic_rows} <- symbolic_search(namespace, plan, limit, opts),
         {:ok, fallback_units} <- list(namespace, opts) do
      candidates =
        [
          Enum.map(lexical_rows, &row_to_candidate(&1, plan)),
          Enum.map(symbolic_rows, &row_to_candidate(&1, plan))
        ]
        |> List.flatten()
        |> Enum.concat(semantic_candidates(fallback_units, plan, limit))
        |> Enum.reduce(%{}, fn candidate, acc ->
          if filters_match?(candidate.unit, plan) do
            Map.update(acc, candidate.unit.id, candidate, &merge_candidates(&1, candidate))
          else
            acc
          end
        end)
        |> Map.values()

      {:ok, candidates}
    end
  end

  defp lexical_search(_namespace, %{keywords: []}, _limit, _opts), do: {:ok, []}

  defp lexical_search(namespace, plan, limit, opts) do
    query = fts_query(plan.keywords)

    sql = """
    SELECT
      m.*,
      CASE
        WHEN bm25(#{fts_table(opts)}) <= 0 THEN 1.0
        ELSE 1.0 / (1.0 + bm25(#{fts_table(opts)}))
      END AS lexical_score,
      0.0 AS semantic_score,
      0.0 AS symbolic_score
    FROM #{fts_table(opts)}
    JOIN #{table(opts)} AS m ON m.rowid = #{fts_table(opts)}.rowid
    WHERE #{fts_table(opts)} MATCH ? AND m.namespace = ?
    ORDER BY bm25(#{fts_table(opts)}) ASC, m.observed_at DESC
    LIMIT ?
    """

    with {:ok, conn} <- open(path(opts)),
         {:ok, rows} <- query(conn, sql, [query, namespace, limit]) do
      Sqlite3.close(conn)
      {:ok, rows}
    end
  end

  defp symbolic_search(namespace, plan, limit, opts) do
    case symbolic_parts(plan, "m") do
      {[], _args, 0} ->
        {:ok, []}

      {parts, args, divisor} ->
        score_expr = Enum.join(parts, " + ")

        sql = """
        SELECT *
        FROM (
          SELECT
            m.*,
            0.0 AS lexical_score,
            0.0 AS semantic_score,
            ((#{score_expr}) * 1.0 / #{divisor}) AS symbolic_score
          FROM #{table(opts)} AS m
          WHERE m.namespace = ?
        ) AS scored
        WHERE scored.symbolic_score > 0
        ORDER BY scored.symbolic_score DESC, scored.observed_at DESC
        LIMIT ?
        """

        with {:ok, conn} <- open(path(opts)),
             {:ok, rows} <- query(conn, sql, [namespace] ++ args ++ [limit]) do
          Sqlite3.close(conn)
          {:ok, rows}
        end
    end
  end

  defp semantic_candidates(units, plan, limit) do
    units
    |> Enum.filter(&filters_match?(&1, plan))
    |> Enum.map(fn unit ->
      %{
        unit: unit,
        lexical_score: 0.0,
        semantic_score: Tokenizer.cosine(plan.query_embedding || [], unit.embedding || []),
        symbolic_score: symbolic_score(unit, plan),
        recency_score: recency_score(unit, plan)
      }
    end)
    |> Enum.sort_by(fn candidate -> {-candidate.semantic_score, -candidate.unit.observed_at} end)
    |> Enum.take(limit)
  end

  defp row_to_candidate(row, plan) do
    unit = row_to_unit(row)

    %{
      unit: unit,
      lexical_score: float_value(row["lexical_score"]),
      semantic_score:
        max(
          float_value(row["semantic_score"]),
          Tokenizer.cosine(plan.query_embedding || [], unit.embedding || [])
        ),
      symbolic_score: max(float_value(row["symbolic_score"]), symbolic_score(unit, plan)),
      recency_score: recency_score(unit, plan)
    }
  end

  defp merge_candidates(left, right) do
    %{
      unit: if(right.unit.observed_at >= left.unit.observed_at, do: right.unit, else: left.unit),
      lexical_score: max(left.lexical_score, right.lexical_score),
      semantic_score: max(left.semantic_score, right.semantic_score),
      symbolic_score: max(left.symbolic_score, right.symbolic_score),
      recency_score: max(left.recency_score, right.recency_score)
    }
  end

  defp row_to_unit(row) do
    {:ok, unit} =
      MemoryUnit.new(%{
        id: row["id"],
        namespace: row["namespace"],
        restatement: row["restatement"],
        original_text: row["original_text"],
        class: parse_class(row["class"]),
        kind: row["kind"],
        tags: decode_json_list(row["tags"]),
        source: row["source"],
        observed_at: row["observed_at"],
        expires_at: row["expires_at"],
        timestamp: row["timestamp"],
        persons: decode_json_list(row["persons"]),
        entities: decode_json_list(row["entities"]),
        location: row["location"],
        topic: row["topic"],
        keywords: decode_json_list(row["keywords"]),
        content: decode_json_map(row["content"]),
        metadata: decode_json_map(row["metadata"]),
        embedding: decode_json_float_list(row["embedding_json"])
      })

    unit
  end

  defp query(conn, sql, args) do
    with {:ok, stmt} <- Sqlite3.prepare(conn, sql),
         :ok <- Sqlite3.bind(stmt, args),
         {:ok, columns} <- Sqlite3.columns(conn, stmt),
         {:ok, rows} <- Sqlite3.fetch_all(conn, stmt) do
      Sqlite3.release(conn, stmt)
      {:ok, Enum.map(rows, &(Enum.zip(columns, &1) |> Map.new()))}
    else
      :done ->
        {:ok, []}

      {:error, _} = error ->
        error
    end
  end

  defp execute(conn, sql, args) do
    with {:ok, stmt} <- Sqlite3.prepare(conn, sql),
         :ok <- Sqlite3.bind(stmt, args),
         :done <- Sqlite3.step(conn, stmt) do
      Sqlite3.release(conn, stmt)
      {:ok, :done}
    else
      {:error, _} = error ->
        error

      other ->
        {:error, other}
    end
  end

  defp execute_script(conn, sql), do: Sqlite3.execute(conn, sql)

  defp open(path), do: Sqlite3.open(path)

  defp ensure_parent_dir(path) do
    path |> Path.dirname() |> File.mkdir_p()
  end

  defp path(opts), do: Keyword.get(opts, :path, @default_path)
  defp table(opts), do: Keyword.get(opts, :table, @default_table)
  defp fts_table(opts), do: table(opts) <> "_fts"

  defp put_args(unit) do
    [
      unit.id,
      unit.namespace,
      unit.restatement,
      unit.original_text,
      Atom.to_string(unit.class),
      to_string(unit.kind),
      Jason.encode!(unit.tags || []),
      unit.source,
      unit.observed_at,
      unit.expires_at,
      unit.timestamp,
      Jason.encode!(unit.persons || []),
      Jason.encode!(unit.entities || []),
      unit.location,
      unit.topic,
      Jason.encode!(unit.keywords || []),
      search_text(unit),
      Jason.encode!(unit.content || %{}),
      Jason.encode!(unit.metadata || %{}),
      Jason.encode!(unit.embedding || [])
    ]
  end

  defp pragma_sql do
    """
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;
    PRAGMA temp_store = MEMORY;
    """
  end

  defp schema_sql(opts) do
    """
    CREATE TABLE IF NOT EXISTS #{table(opts)} (
      id TEXT PRIMARY KEY,
      namespace TEXT NOT NULL,
      restatement TEXT NOT NULL,
      original_text TEXT,
      class TEXT NOT NULL,
      kind TEXT NOT NULL,
      tags TEXT NOT NULL DEFAULT '[]',
      source TEXT,
      observed_at INTEGER NOT NULL,
      expires_at INTEGER,
      timestamp TEXT,
      persons TEXT NOT NULL DEFAULT '[]',
      entities TEXT NOT NULL DEFAULT '[]',
      location TEXT,
      topic TEXT,
      keywords TEXT NOT NULL DEFAULT '[]',
      search_text TEXT NOT NULL DEFAULT '',
      content TEXT NOT NULL DEFAULT '{}',
      metadata TEXT NOT NULL DEFAULT '{}',
      embedding_json TEXT NOT NULL DEFAULT '[]'
    );
    CREATE INDEX IF NOT EXISTS #{table(opts)}_namespace_idx ON #{table(opts)} (namespace);
    CREATE INDEX IF NOT EXISTS #{table(opts)}_observed_idx ON #{table(opts)} (namespace, observed_at DESC);
    CREATE INDEX IF NOT EXISTS #{table(opts)}_location_idx ON #{table(opts)} (namespace, location);
    CREATE INDEX IF NOT EXISTS #{table(opts)}_topic_idx ON #{table(opts)} (namespace, topic);
    CREATE INDEX IF NOT EXISTS #{table(opts)}_timestamp_idx ON #{table(opts)} (namespace, timestamp);
    CREATE VIRTUAL TABLE IF NOT EXISTS #{fts_table(opts)}
    USING fts5(restatement, search_text, tokenize='unicode61');
    CREATE TRIGGER IF NOT EXISTS #{table(opts)}_ai
    AFTER INSERT ON #{table(opts)} BEGIN
      INSERT INTO #{fts_table(opts)}(rowid, restatement, search_text)
      VALUES (new.rowid, new.restatement, new.search_text);
    END;
    CREATE TRIGGER IF NOT EXISTS #{table(opts)}_au
    AFTER UPDATE ON #{table(opts)} BEGIN
      DELETE FROM #{fts_table(opts)} WHERE rowid = old.rowid;
      INSERT INTO #{fts_table(opts)}(rowid, restatement, search_text)
      VALUES (new.rowid, new.restatement, new.search_text);
    END;
    CREATE TRIGGER IF NOT EXISTS #{table(opts)}_ad
    AFTER DELETE ON #{table(opts)} BEGIN
      DELETE FROM #{fts_table(opts)} WHERE rowid = old.rowid;
    END;
    INSERT INTO #{fts_table(opts)}(rowid, restatement, search_text)
    SELECT rowid, restatement, search_text FROM #{table(opts)}
    WHERE rowid NOT IN (SELECT rowid FROM #{fts_table(opts)});
    """
  end

  defp search_text(unit) do
    [
      unit.restatement,
      unit.original_text,
      Enum.join(unit.keywords || [], " "),
      Enum.join(unit.tags || [], " "),
      Enum.join(unit.persons || [], " "),
      Enum.join(unit.entities || [], " "),
      unit.location,
      unit.topic
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp fts_query(keywords) do
    keywords
    |> Enum.map(&~s("#{String.replace(to_string(&1), "\"", "\"\"")}"*))
    |> Enum.join(" OR ")
  end

  defp symbolic_parts(plan, alias_name) do
    {parts, args} =
      {[], []}
      |> maybe_symbolic_json_any(alias_name, "persons", plan.persons || [])
      |> maybe_symbolic_json_any(alias_name, "entities", plan.entities || [])
      |> maybe_symbolic_scalar(alias_name, "location", plan.location)
      |> maybe_symbolic_scalar(alias_name, "timestamp", plan.timestamp_hint)
      |> maybe_symbolic_json_any(alias_name, "tags", plan.tags_any || [])
      |> maybe_symbolic_json_all(alias_name, "tags", plan.tags_all || [])

    {parts, args, length(parts)}
  end

  defp maybe_symbolic_json_any({parts, args}, _alias_name, _field, []), do: {parts, args}

  defp maybe_symbolic_json_any({parts, args}, alias_name, field, values) do
    expr =
      "CASE WHEN EXISTS (SELECT 1 FROM json_each(#{alias_name}.#{field}) WHERE value IN (#{placeholders(length(values))})) THEN 1.0 ELSE 0.0 END"

    {parts ++ [expr], args ++ values}
  end

  defp maybe_symbolic_json_all({parts, args}, _alias_name, _field, []), do: {parts, args}

  defp maybe_symbolic_json_all({parts, args}, alias_name, field, values) do
    expr =
      "CASE WHEN (SELECT COUNT(DISTINCT value) FROM json_each(#{alias_name}.#{field}) WHERE value IN (#{placeholders(length(values))})) = #{length(values)} THEN 1.0 ELSE 0.0 END"

    {parts ++ [expr], args ++ values}
  end

  defp maybe_symbolic_scalar({parts, args}, _alias_name, _field, nil), do: {parts, args}

  defp maybe_symbolic_scalar({parts, args}, alias_name, field, value) do
    expr = "CASE WHEN #{alias_name}.#{field} = ? THEN 1.0 ELSE 0.0 END"
    {parts ++ [expr], args ++ [value]}
  end

  defp filters_match?(unit, plan) do
    class_match?(unit, plan) and
      kind_match?(unit, plan) and
      tags_match?(unit, plan) and
      time_match?(unit, plan)
  end

  defp class_match?(_unit, %{classes: []}), do: true
  defp class_match?(unit, %{classes: classes}), do: unit.class in classes

  defp kind_match?(_unit, %{kinds: []}), do: true
  defp kind_match?(unit, %{kinds: kinds}), do: unit.kind in kinds

  defp tags_match?(unit, %{tags_all: tags_all, tags_any: tags_any}) do
    has_all = Enum.all?(tags_all, &(&1 in unit.tags))
    has_any = tags_any == [] or Enum.any?(tags_any, &(&1 in unit.tags))
    has_all and has_any
  end

  defp time_match?(unit, %{since: since, until: until}) do
    after_since = is_nil(since) or unit.observed_at >= since
    before_until = is_nil(until) or unit.observed_at <= until
    after_since and before_until
  end

  defp symbolic_score(unit, plan) do
    [
      Enum.any?(plan.persons || [], &(&1 in unit.persons)),
      Enum.any?(plan.entities || [], &(&1 in unit.entities)),
      not is_nil(plan.location) and unit.location == plan.location,
      not is_nil(plan.timestamp_hint) and unit.timestamp == plan.timestamp_hint,
      Enum.any?(plan.tags_any || [], &(&1 in unit.tags)),
      Enum.all?(plan.tags_all || [], &(&1 in unit.tags))
    ]
    |> Enum.count(& &1)
    |> case do
      0 -> 0.0
      hits -> hits / 6.0
    end
  end

  defp recency_score(unit, plan) do
    if is_integer(unit.observed_at) and is_integer(plan.now) do
      age_ms = max(plan.now - unit.observed_at, 1)
      1.0 / (1.0 + age_ms / 86_400_000)
    else
      0.0
    end
  end

  defp float_value(nil), do: 0.0
  defp float_value(value) when is_float(value), do: value
  defp float_value(value) when is_integer(value), do: value * 1.0

  defp float_value(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> parsed
      :error -> 0.0
    end
  end

  defp parse_class("semantic"), do: :semantic
  defp parse_class("procedural"), do: :procedural
  defp parse_class("working"), do: :working
  defp parse_class(_), do: :episodic

  defp decode_json_map(nil), do: %{}
  defp decode_json_map(value) when is_map(value), do: value

  defp decode_json_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_json_map(_), do: %{}

  defp decode_json_list(nil), do: []

  defp decode_json_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_list(decoded) -> Enum.map(decoded, &to_string/1)
      _ -> []
    end
  end

  defp decode_json_list(value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp decode_json_list(_), do: []

  defp decode_json_float_list(nil), do: []

  defp decode_json_float_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_list(decoded) ->
        Enum.map(decoded, fn
          value when is_float(value) -> value
          value when is_integer(value) -> value * 1.0
          value -> value |> to_string() |> String.to_float()
        end)

      _ ->
        []
    end
  end

  defp decode_json_float_list(_), do: []

  defp placeholders(count) when count > 0, do: Enum.map_join(1..count, ", ", fn _ -> "?" end)
  defp placeholders(_count), do: "?"
end
