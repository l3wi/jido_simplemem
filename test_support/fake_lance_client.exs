defmodule Jido.SimpleMem.TestSupport.FakeLanceClient do
  @behaviour Jido.SimpleMem.Store.Lance.Client

  def ensure_ready(opts) do
    _ = ensure_table(opts)
    :ok
  end

  def put(unit, opts) do
    table = ensure_table(opts)

    :ets.insert(
      table,
      {{unit["namespace"], unit["entry_id"]}, unit}
    )

    {:ok, unit}
  end

  def get(namespace, id, opts) do
    table = ensure_table(opts)

    case :ets.lookup(table, {namespace, id}) do
      [{{^namespace, ^id}, row}] -> {:ok, row}
      [] -> :not_found
    end
  end

  def delete(namespace, id, opts) do
    table = ensure_table(opts)
    :ets.delete(table, {namespace, id})
    :ok
  end

  def list(namespace, opts) do
    table = ensure_table(opts)

    rows =
      table
      |> :ets.tab2list()
      |> Enum.map(&elem(&1, 1))
      |> Enum.filter(&(&1["namespace"] == namespace))
      |> Enum.sort_by(&(&1["observed_at"] || 0), :desc)

    {:ok, rows}
  end

  def search(namespace, plan, opts) do
    {:ok, rows} = list(namespace, opts)
    fetch_limit = plan[:fetch_limit] || plan[:limit] || 10

    candidates =
      rows
      |> Enum.map(&score_candidate(&1, plan))
      |> Enum.reject(fn candidate ->
        candidate["lexical_score"] == 0.0 and candidate["semantic_score"] == 0.0 and
          candidate["symbolic_score"] == 0.0
      end)
      |> Enum.sort_by(fn candidate ->
        {
          source_priority(candidate),
          candidate["structured_rank"] || 9_999,
          candidate["semantic_rank"] || 9_999,
          candidate["lexical_rank"] || 9_999,
          -(candidate["symbolic_score"] + candidate["semantic_score"] + candidate["lexical_score"])
        }
      end)
      |> Enum.take(fetch_limit)

    {:ok, candidates}
  end

  def load_buffer(namespace, session_id, opts) do
    table = ensure_buffer_table(opts)

    case :ets.lookup(table, {namespace, session_id}) do
      [{{^namespace, ^session_id}, state}] when is_map(state) ->
        {:ok, state}

      [{{^namespace, ^session_id}, dialogues}] ->
        {:ok, %{dialogues: dialogues, recent_entries: [], processed_cursor: 0}}

      [] ->
        {:ok, %{dialogues: [], recent_entries: [], processed_cursor: 0}}
    end
  end

  def replace_buffer(namespace, session_id, state, opts) do
    table = ensure_buffer_table(opts)
    normalized =
      case state do
        %{} = value ->
          %{
            dialogues: value[:dialogues] || value["dialogues"] || [],
            recent_entries: value[:recent_entries] || value["recent_entries"] || [],
            processed_cursor: value[:processed_cursor] || value["processed_cursor"] || 0
          }

        other ->
          %{dialogues: other, recent_entries: [], processed_cursor: 0}
      end

    :ets.insert(table, {{namespace, session_id}, normalized})
    :ok
  end

  def delete_buffer(namespace, session_id, opts) do
    table = ensure_buffer_table(opts)
    :ets.delete(table, {namespace, session_id})
    :ok
  end

  defp ensure_table(opts) do
    table = table_name(opts, "memories")

    case :ets.whereis(table) do
      :undefined -> :ets.new(table, table_options(table))
      _ -> table
    end
  end

  defp ensure_buffer_table(opts) do
    table = table_name(opts, "buffers")

    case :ets.whereis(table) do
      :undefined -> :ets.new(table, table_options(table))
      _ -> table
    end
  end

  defp table_name(opts, suffix) do
    hash = :erlang.phash2({Keyword.get(opts, :path, "default"), suffix})
    String.to_atom("jido_simplemem_fake_lance_#{suffix}_#{hash}")
  end

  defp table_options(table) do
    base = [:named_table, :public, :set]

    case Process.whereis(Jido.SimpleMem.JobRunner) do
      pid when is_pid(pid) ->
        base ++ [{:heir, pid, {:ets_heir, table}}]

      _ ->
        base
    end
  end

  defp score_candidate(row, plan) do
    lexical_overlap =
      overlap(plan[:keywords] || [], row["keywords"] || []) +
        overlap(plan[:keywords] || [], String.split(String.downcase(row["lossless_restatement"] || "")))

    semantic_score =
      cosine(plan[:query_embedding] || [], row["vector"] || [])

    symbolic_hits =
      Enum.count([
        Enum.any?(plan[:persons] || [], &(&1 in (row["persons"] || []))),
        Enum.any?(plan[:entities] || [], &(&1 in (row["entities"] || []))),
        not is_nil(plan[:location]) and row["location"] == plan[:location],
        time_match?(row["timestamp"], plan[:time_expression])
      ], & &1)

    channels =
      []
      |> maybe_add_channel(:structured, symbolic_hits > 0)
      |> maybe_add_channel(:semantic, semantic_score > 0.0)
      |> maybe_add_channel(:keyword, lexical_overlap > 0)

    %{
      "unit" => row,
      "lexical_score" => lexical_overlap / max(length(plan[:keywords] || []), 1),
      "semantic_score" => semantic_score,
      "symbolic_score" => symbolic_hits / 4.0,
      "recency_score" => 0.5,
      "channels" => Enum.map(channels, &Atom.to_string/1),
      "lexical_rank" => if(lexical_overlap > 0, do: 1, else: nil),
      "semantic_rank" => if(semantic_score > 0.0, do: 1, else: nil),
      "structured_rank" => if(symbolic_hits > 0, do: 1, else: nil)
    }
  end

  defp maybe_add_channel(channels, _channel, false), do: channels
  defp maybe_add_channel(channels, channel, true), do: channels ++ [channel]

  defp source_priority(%{"channels" => channels}) do
    cond do
      "structured" in channels -> 0
      "semantic" in channels -> 1
      "keyword" in channels -> 2
      true -> 3
    end
  end

  defp overlap(left, right) do
    left = MapSet.new(Enum.map(left, &String.downcase(to_string(&1))))
    right = MapSet.new(Enum.map(right, &String.downcase(to_string(&1))))
    MapSet.intersection(left, right) |> MapSet.size()
  end

  defp cosine([], _), do: 0.0
  defp cosine(_, []), do: 0.0

  defp cosine(left, right) do
    pairs = Enum.zip(left, right)
    dot = Enum.reduce(pairs, 0.0, fn {a, b}, acc -> acc + a * b end)
    left_norm = :math.sqrt(Enum.reduce(left, 0.0, fn x, acc -> acc + x * x end))
    right_norm = :math.sqrt(Enum.reduce(right, 0.0, fn x, acc -> acc + x * x end))

    if left_norm == 0.0 or right_norm == 0.0, do: 0.0, else: dot / (left_norm * right_norm)
  end

  defp time_match?(_timestamp, nil), do: false
  defp time_match?(nil, _time_expression), do: false

  defp time_match?(timestamp, time_expression) do
    String.contains?(String.downcase(timestamp), String.downcase(to_string(time_expression)))
  end
end
