defmodule Jido.SimpleMem.Store.Lance do
  @moduledoc """
  LanceDB-backed storage for core SimpleMem parity.

  The store delegates LanceDB operations to a local Python worker that uses the
  official LanceDB SDK and Tantivy-backed FTS for local indexing.
  """

  @behaviour Jido.SimpleMem.Store

  alias Jido.SimpleMem.{Dialogue, MemoryUnit}
  alias Jido.SimpleMem.Store.Lance.PortClient

  @impl true
  def ensure_ready(opts) do
    case client(opts).ensure_ready(client_opts(opts)) do
      {:ok, :ok} -> :ok
      other -> other
    end
  end

  @impl true
  def put(%MemoryUnit{} = unit, opts) do
    with {:ok, row} <- client(opts).put(unit_to_map(unit), client_opts(opts)) do
      {:ok, row_to_unit(row)}
    end
  end

  @impl true
  def get({namespace, id}, opts) do
    case client(opts).get(namespace, id, client_opts(opts)) do
      {:ok, row} when is_map(row) -> {:ok, row_to_unit(row)}
      :not_found -> :not_found
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def delete({namespace, id}, opts) do
    case client(opts).delete(namespace, id, client_opts(opts)) do
      {:ok, :ok} -> :ok
      other -> other
    end
  end

  @impl true
  def list(namespace, opts) do
    with {:ok, rows} <- client(opts).list(namespace, client_opts(opts)) do
      {:ok, Enum.map(rows, &row_to_unit/1)}
    end
  end

  @impl true
  def search(namespace, plan, opts) do
    with {:ok, rows} <- client(opts).search(namespace, plan, client_opts(opts)) do
      {:ok, Enum.map(rows, &row_to_candidate/1)}
    end
  end

  @impl true
  def load_buffer(namespace, session_id, opts) do
    with {:ok, state} <- client(opts).load_buffer(namespace, session_id, client_opts(opts)) do
      {:ok,
       %{
         dialogues: Enum.map(state["dialogues"] || state[:dialogues] || [], &dialogue_to_map/1),
         recent_entries:
           Enum.map(state["recent_entries"] || state[:recent_entries] || [], &row_to_unit/1),
         processed_cursor:
           integer_value(state["processed_cursor"] || state[:processed_cursor]) || 0
       }}
    end
  end

  @impl true
  def replace_buffer(namespace, session_id, state, opts) do
    case client(opts).replace_buffer(
           namespace,
           session_id,
           %{
             "dialogues" =>
               Enum.map(state[:dialogues] || state["dialogues"] || [], &dialogue_to_map/1),
             "recent_entries" =>
               Enum.map(state[:recent_entries] || state["recent_entries"] || [], &unit_to_map/1),
             "processed_cursor" => state[:processed_cursor] || state["processed_cursor"] || 0
           },
           client_opts(opts)
         ) do
      {:ok, :ok} -> :ok
      other -> other
    end
  end

  @impl true
  def delete_buffer(namespace, session_id, opts) do
    case client(opts).delete_buffer(namespace, session_id, client_opts(opts)) do
      {:ok, :ok} -> :ok
      other -> other
    end
  end

  defp row_to_candidate(row) do
    %{
      unit: row_to_unit(row["unit"] || row[:unit] || row),
      lexical_score: float_value(row["lexical_score"] || row[:lexical_score]),
      semantic_score: float_value(row["semantic_score"] || row[:semantic_score]),
      symbolic_score: float_value(row["symbolic_score"] || row[:symbolic_score]),
      recency_score: float_value(row["recency_score"] || row[:recency_score]),
      channels: normalize_channels(row["channels"] || row[:channels] || []),
      lexical_rank: integer_value(row["lexical_rank"] || row[:lexical_rank]),
      semantic_rank: integer_value(row["semantic_rank"] || row[:semantic_rank]),
      structured_rank: integer_value(row["structured_rank"] || row[:structured_rank])
    }
  end

  defp row_to_unit(row) do
    {:ok, unit} =
      MemoryUnit.new(%{
        id: row["entry_id"] || row[:entry_id] || row["id"] || row[:id],
        namespace: row["namespace"] || row[:namespace],
        restatement:
          row["lossless_restatement"] || row[:lossless_restatement] || row["restatement"] ||
            row[:restatement],
        original_text: row["original_text"] || row[:original_text],
        content: normalize_map(row["content"] || row[:content]),
        class: normalize_class(row["class"] || row[:class]),
        kind: row["kind"] || row[:kind] || :memory,
        tags: normalize_list(row["tags"] || row[:tags]),
        source: row["source"] || row[:source],
        observed_at:
          integer_value(row["observed_at"] || row[:observed_at]) ||
            System.system_time(:millisecond),
        expires_at: integer_value(row["expires_at"] || row[:expires_at]),
        timestamp: row["timestamp"] || row[:timestamp],
        persons: normalize_list(row["persons"] || row[:persons]),
        entities: normalize_list(row["entities"] || row[:entities]),
        location: row["location"] || row[:location],
        topic: row["topic"] || row[:topic],
        keywords: normalize_list(row["keywords"] || row[:keywords]),
        metadata: normalize_map(row["metadata"] || row[:metadata]),
        embedding:
          normalize_floats(row["vector"] || row[:vector] || row["embedding"] || row[:embedding])
      })

    unit
  end

  defp unit_to_map(%MemoryUnit{} = unit) do
    %{
      "entry_id" => unit.id,
      "namespace" => unit.namespace,
      "lossless_restatement" => unit.restatement,
      "original_text" => unit.original_text,
      "content" => unit.content,
      "class" => to_string(unit.class),
      "kind" => to_string(unit.kind),
      "tags" => unit.tags,
      "source" => unit.source,
      "observed_at" => unit.observed_at,
      "expires_at" => unit.expires_at,
      "timestamp" => unit.timestamp,
      "persons" => unit.persons,
      "entities" => unit.entities,
      "location" => unit.location,
      "topic" => unit.topic,
      "keywords" => unit.keywords,
      "metadata" => unit.metadata,
      "vector" => unit.embedding
    }
  end

  defp dialogue_to_map(%Dialogue{} = dialogue) do
    %{
      "dialogue_id" => dialogue.dialogue_id,
      "speaker" => dialogue.speaker,
      "content" => dialogue.content,
      "timestamp" => dialogue.timestamp,
      "metadata" => dialogue.metadata
    }
  end

  defp dialogue_to_map(%{} = dialogue) do
    %{
      "dialogue_id" => dialogue["dialogue_id"] || dialogue[:dialogue_id],
      "speaker" => dialogue["speaker"] || dialogue[:speaker],
      "content" => dialogue["content"] || dialogue[:content],
      "timestamp" => dialogue["timestamp"] || dialogue[:timestamp],
      "metadata" => dialogue["metadata"] || dialogue[:metadata] || %{}
    }
  end

  defp client(opts), do: Keyword.get(opts, :client, PortClient)

  defp client_opts(opts) do
    opts
    |> Keyword.delete(:client)
  end

  defp normalize_map(%{} = map), do: map
  defp normalize_map(nil), do: %{}
  defp normalize_map(_), do: %{}

  defp normalize_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp normalize_list(nil), do: []
  defp normalize_list(value), do: [to_string(value)]

  defp normalize_channels(list) when is_list(list),
    do: Enum.map(list, &String.to_atom(to_string(&1)))

  defp normalize_channels(_), do: []

  defp normalize_floats(list) when is_list(list), do: Enum.map(list, &float_value/1)
  defp normalize_floats(_), do: []

  defp float_value(value) when is_float(value), do: value
  defp float_value(value) when is_integer(value), do: value * 1.0

  defp float_value(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> parsed
      :error -> 0.0
    end
  end

  defp float_value(_), do: 0.0

  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(value) when is_float(value), do: trunc(value)

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp integer_value(_), do: nil

  defp normalize_class(nil), do: :episodic
  defp normalize_class(value) when is_atom(value), do: value

  defp normalize_class(value) when is_binary(value) do
    try do
      String.to_existing_atom(value)
    rescue
      ArgumentError -> :episodic
    end
  end
end
