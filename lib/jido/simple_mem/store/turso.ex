defmodule Jido.SimpleMem.Store.Turso do
  @moduledoc """
  Turso/libSQL-backed storage for SimpleMem units.

  The adapter uses three retrieval channels:

  - FTS5 lexical search over restatements and extracted metadata
  - native vector search over embeddings
  - symbolic filtering over exact metadata matches

  Candidate sets are merged in Elixir and then handed to the shared ranker.
  """

  @behaviour Jido.SimpleMem.Store

  alias Jido.SimpleMem.MemoryUnit
  alias Jido.SimpleMem.Store.Turso.HttpClient

  @default_table "simplemem_units"
  @default_vector_dimensions 32
  @default_candidate_limit 25

  @type result_row :: map()

  @impl true
  def ensure_ready(opts) do
    statements = [
      {create_table_sql(opts), []},
      {create_namespace_index_sql(opts), []},
      {create_time_index_sql(opts), []},
      {create_class_kind_index_sql(opts), []},
      {create_location_index_sql(opts), []},
      {create_topic_index_sql(opts), []},
      {create_timestamp_index_sql(opts), []},
      {create_vector_index_sql(opts), []},
      {create_fts_table_sql(opts), []},
      {create_insert_trigger_sql(opts), []},
      {create_update_trigger_sql(opts), []},
      {create_delete_trigger_sql(opts), []},
      {backfill_fts_sql(opts), []}
    ]

    with {:ok, _} <- client(opts).batch(statements, client_opts(opts)) do
      :ok
    end
  end

  @impl true
  def put(%MemoryUnit{} = unit, opts) do
    sql = """
    INSERT INTO #{table(opts)} (
      id, namespace, restatement, original_text, class, kind, tags, source, observed_at,
      expires_at, timestamp, persons, entities, location, topic, keywords, search_text,
      content, metadata, embedding, embedding_json
    )
    VALUES (
      ?, ?, ?, ?, ?, ?, ?, ?, ?,
      ?, ?, ?, ?, ?, ?, ?, ?,
      ?, ?, vector32(?), ?
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
      embedding = excluded.embedding,
      embedding_json = excluded.embedding_json
    """

    with {:ok, _} <- client(opts).execute(sql, put_args(unit), client_opts(opts)) do
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

    with {:ok, %{rows: rows}} <- client(opts).execute(sql, [namespace, id], client_opts(opts)) do
      case rows do
        [row | _] -> {:ok, row_to_unit(row)}
        [] -> :not_found
      end
    end
  end

  @impl true
  def delete({namespace, id}, opts) do
    sql = "DELETE FROM #{table(opts)} WHERE namespace = ? AND id = ?"

    with {:ok, _} <- client(opts).execute(sql, [namespace, id], client_opts(opts)) do
      :ok
    end
  end

  @impl true
  def list(namespace, opts) do
    {sql, args} =
      select_rows_sql(namespace, %{}, opts,
        order_by: "ORDER BY observed_at DESC",
        limit: nil
      )

    with {:ok, %{rows: rows}} <- client(opts).execute(sql, args, client_opts(opts)) do
      {:ok, Enum.map(rows, &row_to_unit/1)}
    end
  end

  @impl true
  def search(namespace, plan, opts) do
    limit = fanout_limit(plan)

    with {:ok, lexical_rows} <- lexical_search(namespace, plan, limit, opts),
         {:ok, semantic_rows} <- semantic_search(namespace, plan, limit, opts),
         {:ok, symbolic_rows} <- symbolic_search(namespace, plan, limit, opts),
         {:ok, fallback_rows} <- fallback_search(namespace, plan, limit, opts) do
      candidates =
        [lexical_rows, semantic_rows, symbolic_rows, fallback_rows]
        |> Enum.flat_map(& &1)
        |> Enum.reduce(%{}, fn row, acc ->
          candidate = row_to_candidate(row, plan)

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
    #{where_clause(namespace, plan, opts, alias: "m", prefix: "WHERE", extra: ["#{fts_table(opts)} MATCH ?"])}
    ORDER BY bm25(#{fts_table(opts)}) ASC, m.observed_at DESC
    LIMIT ?
    """

    args = [query | where_args(namespace, plan)] ++ [limit]

    execute_rows(sql, args, opts)
  end

  defp semantic_search(_namespace, %{query_embedding: []}, _limit, _opts), do: {:ok, []}

  defp semantic_search(namespace, plan, limit, opts) do
    vector_json = Jason.encode!(plan.query_embedding)
    prelimit = max(limit * 4, limit)

    sql = """
    SELECT
      m.*,
      0.0 AS lexical_score,
      MAX(0.0, 1.0 - vector_distance_cos(m.embedding, vector32(?))) AS semantic_score,
      0.0 AS symbolic_score
    FROM vector_top_k('#{vector_index(opts)}', vector32(?), ?) AS vt
    JOIN #{table(opts)} AS m ON m.rowid = vt.id
    #{where_clause(namespace, plan, opts, alias: "m", prefix: "WHERE")}
    ORDER BY vector_distance_cos(m.embedding, vector32(?)) ASC, m.observed_at DESC
    LIMIT ?
    """

    args =
      [vector_json, vector_json, prelimit] ++ where_args(namespace, plan) ++ [vector_json, limit]

    execute_rows(sql, args, opts)
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
          #{where_clause(namespace, plan, opts, alias: "m", prefix: "WHERE")}
        ) AS scored
        WHERE scored.symbolic_score > 0
        ORDER BY scored.symbolic_score DESC, scored.observed_at DESC
        LIMIT ?
        """

        execute_rows(sql, where_args(namespace, plan) ++ args ++ [limit], opts)
    end
  end

  defp fallback_search(namespace, plan, limit, opts) do
    {sql, args} =
      select_rows_sql(namespace, plan, opts,
        order_by: "ORDER BY observed_at DESC",
        limit: limit,
        include_scores: true
      )

    execute_rows(sql, args, opts)
  end

  defp execute_rows(sql, args, opts) do
    with {:ok, %{rows: rows}} <- client(opts).execute(sql, args, client_opts(opts)) do
      {:ok, rows}
    end
  end

  defp row_to_candidate(row, plan) do
    unit = row_to_unit(row)

    %{
      unit: unit,
      lexical_score: float_value(row["lexical_score"]),
      semantic_score: float_value(row["semantic_score"]),
      symbolic_score: float_value(row["symbolic_score"]),
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
        embedding: decode_json_list(row["embedding_json"])
      })

    unit
  end

  defp decode_json_list(nil), do: []

  defp decode_json_list(value) when is_list(value) do
    Enum.map(value, fn
      value when is_float(value) -> value
      value -> to_string(value)
    end)
  end

  defp decode_json_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_list(decoded) ->
        Enum.map(decoded, fn
          value when is_float(value) -> value
          value when is_integer(value) -> value * 1.0
          value -> to_string(value)
        end)

      _ ->
        []
    end
  end

  defp decode_json_list(_), do: []

  defp decode_json_map(nil), do: %{}
  defp decode_json_map(value) when is_map(value), do: value

  defp decode_json_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_json_map(_), do: %{}

  defp fanout_limit(plan), do: max((plan.limit || 10) * 3, @default_candidate_limit)

  defp fts_query(keywords) do
    keywords
    |> Enum.map(&~s("#{String.replace(to_string(&1), "\"", "\"\"")}"*))
    |> Enum.join(" OR ")
  end

  defp put_args(unit) do
    embedding_json = Jason.encode!(unit.embedding || [])

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
      embedding_json,
      embedding_json
    ]
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

  defp recency_score(unit, plan) do
    if is_integer(unit.observed_at) and is_integer(plan.now) do
      age_ms = max(plan.now - unit.observed_at, 1)
      1.0 / (1.0 + age_ms / 86_400_000)
    else
      0.0
    end
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

  defp client(opts), do: Keyword.get(opts, :client, HttpClient)

  defp client_opts(opts) do
    opts
    |> Keyword.get(:client_opts, [])
    |> Keyword.merge(
      Keyword.take(opts, [
        :url,
        :database_url,
        :pipeline_url,
        :auth_token,
        :receive_timeout,
        :connect_options
      ])
    )
  end

  defp table(opts), do: Keyword.get(opts, :table, @default_table)
  defp fts_table(opts), do: table(opts) <> "_fts"
  defp vector_index(opts), do: table(opts) <> "_embedding_idx"
  defp vector_dimensions(opts), do: Keyword.get(opts, :dimensions, @default_vector_dimensions)

  defp create_table_sql(opts) do
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
      embedding F32_BLOB(#{vector_dimensions(opts)}),
      embedding_json TEXT NOT NULL DEFAULT '[]'
    )
    """
  end

  defp create_namespace_index_sql(opts),
    do: "CREATE INDEX IF NOT EXISTS #{table(opts)}_namespace_idx ON #{table(opts)} (namespace)"

  defp create_time_index_sql(opts),
    do:
      "CREATE INDEX IF NOT EXISTS #{table(opts)}_observed_at_idx ON #{table(opts)} (namespace, observed_at DESC)"

  defp create_class_kind_index_sql(opts),
    do:
      "CREATE INDEX IF NOT EXISTS #{table(opts)}_class_kind_idx ON #{table(opts)} (namespace, class, kind)"

  defp create_location_index_sql(opts),
    do:
      "CREATE INDEX IF NOT EXISTS #{table(opts)}_location_idx ON #{table(opts)} (namespace, location)"

  defp create_topic_index_sql(opts),
    do: "CREATE INDEX IF NOT EXISTS #{table(opts)}_topic_idx ON #{table(opts)} (namespace, topic)"

  defp create_timestamp_index_sql(opts),
    do:
      "CREATE INDEX IF NOT EXISTS #{table(opts)}_timestamp_idx ON #{table(opts)} (namespace, timestamp)"

  defp create_vector_index_sql(opts) do
    "CREATE INDEX IF NOT EXISTS #{vector_index(opts)} ON #{table(opts)}(libsql_vector_idx(embedding))"
  end

  defp create_fts_table_sql(opts) do
    """
    CREATE VIRTUAL TABLE IF NOT EXISTS #{fts_table(opts)}
    USING fts5(restatement, search_text, tokenize='unicode61')
    """
  end

  defp create_insert_trigger_sql(opts) do
    """
    CREATE TRIGGER IF NOT EXISTS #{table(opts)}_ai
    AFTER INSERT ON #{table(opts)} BEGIN
      INSERT INTO #{fts_table(opts)}(rowid, restatement, search_text)
      VALUES (new.rowid, new.restatement, new.search_text);
    END
    """
  end

  defp create_update_trigger_sql(opts) do
    """
    CREATE TRIGGER IF NOT EXISTS #{table(opts)}_au
    AFTER UPDATE ON #{table(opts)} BEGIN
      DELETE FROM #{fts_table(opts)} WHERE rowid = old.rowid;
      INSERT INTO #{fts_table(opts)}(rowid, restatement, search_text)
      VALUES (new.rowid, new.restatement, new.search_text);
    END
    """
  end

  defp create_delete_trigger_sql(opts) do
    """
    CREATE TRIGGER IF NOT EXISTS #{table(opts)}_ad
    AFTER DELETE ON #{table(opts)} BEGIN
      DELETE FROM #{fts_table(opts)} WHERE rowid = old.rowid;
    END
    """
  end

  defp backfill_fts_sql(opts) do
    """
    INSERT INTO #{fts_table(opts)}(rowid, restatement, search_text)
    SELECT rowid, restatement, search_text FROM #{table(opts)}
    WHERE rowid NOT IN (SELECT rowid FROM #{fts_table(opts)})
    """
  end

  defp select_rows_sql(namespace, plan, opts, opts2) do
    select_scores =
      if Keyword.get(opts2, :include_scores, false) do
        ", 0.0 AS lexical_score, 0.0 AS semantic_score, 0.0 AS symbolic_score"
      else
        ""
      end

    limit_clause = if Keyword.get(opts2, :limit), do: "LIMIT ?", else: ""

    sql = """
    SELECT *#{select_scores}
    FROM #{table(opts)}
    #{where_clause(namespace, plan, opts, alias: nil, prefix: "WHERE")}
    #{Keyword.get(opts2, :order_by, "")}
    #{limit_clause}
    """

    args =
      where_args(namespace, plan) ++ if(limit = Keyword.get(opts2, :limit), do: [limit], else: [])

    {sql, args}
  end

  defp where_clause(_namespace, plan, _opts, clause_opts) do
    alias_prefix =
      case Keyword.get(clause_opts, :alias) do
        nil -> ""
        value -> value <> "."
      end

    clauses = ["#{alias_prefix}namespace = ?"] ++ plan_filter_clauses(plan, alias_prefix)
    prefix = Keyword.get(clause_opts, :prefix, "WHERE")
    extra = Keyword.get(clause_opts, :extra, [])
    all = extra ++ clauses

    if all == [] do
      ""
    else
      prefix <> " " <> Enum.join(all, " AND ")
    end
  end

  defp where_args(namespace, plan) do
    [namespace] ++ plan_filter_args(plan)
  end

  defp plan_filter_clauses(plan, alias_prefix) do
    []
    |> maybe_add(is_integer(plan.since), "#{alias_prefix}observed_at >= ?")
    |> maybe_add(is_integer(plan.until), "#{alias_prefix}observed_at <= ?")
    |> maybe_add(
      plan.classes != [],
      "#{alias_prefix}class IN (#{placeholders(length(plan.classes))})"
    )
    |> maybe_add(plan.kinds != [], "#{alias_prefix}kind IN (#{placeholders(length(plan.kinds))})")
  end

  defp plan_filter_args(plan) do
    []
    |> maybe_concat(is_integer(plan.since), [plan.since])
    |> maybe_concat(is_integer(plan.until), [plan.until])
    |> maybe_concat(plan.classes != [], Enum.map(plan.classes, &Atom.to_string/1))
    |> maybe_concat(plan.kinds != [], Enum.map(plan.kinds, &to_string/1))
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

  defp maybe_add(list, true, clause), do: list ++ [clause]
  defp maybe_add(list, false, _clause), do: list

  defp maybe_concat(list, true, values), do: list ++ values
  defp maybe_concat(list, false, _values), do: list

  defp placeholders(count) when count > 0, do: Enum.map_join(1..count, ", ", fn _ -> "?" end)
  defp placeholders(_count), do: "?"
end
