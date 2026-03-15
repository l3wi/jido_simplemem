defmodule Jido.SimpleMem.Extractor do
  @moduledoc false

  alias Jido.SimpleMem.{MemoryUnit, Tokenizer}

  @spec extract(map(), map()) :: {:ok, MemoryUnit.t()} | {:error, term()}
  def extract(attrs, runtime) do
    attrs = normalize_map(attrs)
    observed_at = Map.get(attrs, :observed_at, runtime.now)
    text = pick(attrs, :text) || extract_text(attrs)
    timestamp = pick(attrs, :timestamp) || anchor_relative_time(text, observed_at)
    persons = pick_list(attrs, :persons, extract_persons(text))
    location = pick(attrs, :location) || extract_location(text)
    entities = pick_list(attrs, :entities, [])
    topic = pick(attrs, :topic) || infer_topic(text)
    keywords = keywords(text, persons, entities, location, topic)

    restatement = pick(attrs, :restatement) || restatement(text, persons, timestamp, location)

    with {:ok, embedding} <- embed(restatement, runtime) do
      MemoryUnit.new(%{
        id: Map.get(attrs, :id),
        namespace: runtime.namespace,
        restatement: restatement,
        original_text: text,
        content: Map.get(attrs, :content, %{}),
        class: Map.get(attrs, :class, :episodic),
        kind: Map.get(attrs, :kind, :event),
        tags: Map.get(attrs, :tags, []),
        source: Map.get(attrs, :source),
        observed_at: observed_at,
        expires_at: Map.get(attrs, :expires_at),
        timestamp: timestamp,
        persons: persons,
        entities: entities,
        location: location,
        topic: topic,
        keywords: keywords,
        metadata: Map.get(attrs, :metadata, %{}),
        embedding: embedding
      })
    end
  end

  defp extract_text(attrs) do
    cond do
      is_binary(attrs[:text]) -> attrs[:text]
      is_binary(attrs["text"]) -> attrs["text"]
      is_binary(attrs[:question]) -> attrs[:question]
      is_map(attrs[:content]) -> inspect(attrs[:content])
      true -> "memory event"
    end
  end

  defp pick(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp pick_list(attrs, key, fallback) do
    case pick(attrs, key) do
      nil -> fallback
      list when is_list(list) -> Enum.map(list, &to_string/1)
      value -> [to_string(value)]
    end
  end

  defp restatement(text, persons, timestamp, location) do
    text
    |> replace_pronouns(persons)
    |> maybe_replace_relative_time(timestamp)
    |> maybe_append_location(location)
    |> ensure_sentence()
  end

  defp replace_pronouns(text, []), do: text

  defp replace_pronouns(text, persons) do
    subject =
      case persons do
        [one] -> one
        [one, two | _] -> "#{one} and #{two}"
      end

    Regex.replace(~r/\b(he|she|they|them|their)\b/i, text, subject)
  end

  defp maybe_replace_relative_time(text, nil), do: text

  defp maybe_replace_relative_time(text, timestamp),
    do: String.replace(text, ~r/\b(today|tomorrow|yesterday)\b/i, timestamp)

  defp maybe_append_location(text, nil), do: text

  defp maybe_append_location(text, location) do
    if String.contains?(String.downcase(text), String.downcase(location)) do
      text
    else
      text <> " at " <> location
    end
  end

  defp ensure_sentence(text) do
    trimmed = String.trim(text)
    if String.ends_with?(trimmed, "."), do: trimmed, else: trimmed <> "."
  end

  defp anchor_relative_time(text, observed_at) do
    datetime = DateTime.from_unix!(observed_at, :millisecond)

    cond do
      String.match?(text, ~r/\btomorrow\b/i) ->
        datetime |> DateTime.add(86_400, :second) |> iso8601_seconds()

      String.match?(text, ~r/\byesterday\b/i) ->
        datetime |> DateTime.add(-86_400, :second) |> iso8601_seconds()

      String.match?(text, ~r/\btoday\b/i) ->
        iso8601_seconds(datetime)

      true ->
        nil
    end
  end

  defp extract_persons(text) do
    ~r/\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?\b/u
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.reject(&(&1 in ["I"]))
    |> Enum.uniq()
  end

  defp extract_location(text) do
    case Regex.run(~r/\bat\s+([A-Z][\w-]*(?:\s+[A-Z][\w-]*)*)/u, text, capture: :all_but_first) do
      [location] -> location
      _ -> nil
    end
  end

  defp infer_topic(text) do
    text
    |> Tokenizer.keywords(limit: 3)
    |> Enum.join(" ")
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp keywords(text, persons, entities, location, topic) do
    (Tokenizer.keywords(text) ++ persons ++ entities ++ List.wrap(location) ++ List.wrap(topic))
    |> Enum.uniq()
  end

  defp embed(text, runtime) do
    case runtime.embedding_client.embed(text, runtime.embedding_opts) do
      {:ok, vector} -> {:ok, vector}
      {:error, _reason} = error -> error
      other -> {:error, other}
    end
  end

  defp iso8601_seconds(datetime) do
    datetime
    |> DateTime.to_iso8601()
    |> String.replace(".000Z", "Z")
  end

  defp normalize_map(%{} = map), do: map
  defp normalize_map(list) when is_list(list), do: Map.new(list)
  defp normalize_map(_), do: %{}
end
