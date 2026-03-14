defmodule Jido.SimpleMem.Extractor do
  @moduledoc false

  alias Jido.SimpleMem.{MemoryUnit, Tokenizer}

  @spec extract(map(), map()) :: {:ok, MemoryUnit.t()} | {:error, term()}
  def extract(attrs, runtime) do
    attrs = normalize_map(attrs)
    llm_attrs = maybe_llm_extract(attrs, runtime)

    observed_at = Map.get(attrs, :observed_at, runtime.now)
    text = pick(attrs, llm_attrs, :text) || extract_text(attrs)
    timestamp = pick(attrs, llm_attrs, :timestamp) || anchor_relative_time(text, observed_at)
    persons = pick_list(attrs, llm_attrs, :persons, extract_persons(text))
    location = pick(attrs, llm_attrs, :location) || extract_location(text)
    entities = pick_list(attrs, llm_attrs, :entities, [])
    topic = pick(attrs, llm_attrs, :topic) || infer_topic(text)
    keywords = keywords(text, persons, entities, location, topic)

    restatement =
      pick(attrs, llm_attrs, :restatement) || restatement(text, persons, timestamp, location)

    embedding = embed(restatement, runtime)

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

  defp maybe_llm_extract(attrs, runtime) do
    client = runtime.llm_client

    if function_exported?(client, :extract, 2) do
      case client.extract(attrs, runtime.llm_opts) do
        {:ok, result} when is_map(result) -> result
        _ -> %{}
      end
    else
      %{}
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

  defp pick(attrs, llm_attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) || Map.get(llm_attrs, key) ||
      Map.get(llm_attrs, Atom.to_string(key))
  end

  defp pick_list(attrs, llm_attrs, key, fallback) do
    case pick(attrs, llm_attrs, key) do
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
      {:ok, vector} -> vector
      _ -> []
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
