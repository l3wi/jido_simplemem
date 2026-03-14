defmodule Jido.SimpleMem.Policy do
  @moduledoc """
  Default memory policy for durable turn capture and signal auto-capture.
  """

  @type options :: %{
          capture_explicit_memories: boolean(),
          capture_queries: boolean(),
          capture_responses: boolean(),
          capture_tool_results: boolean(),
          max_memories_per_turn: pos_integer()
        }

  @default_options %{
    capture_explicit_memories: true,
    capture_queries: false,
    capture_responses: false,
    capture_tool_results: true,
    max_memories_per_turn: 6
  }

  @tool_result_types MapSet.new(["ai.tool.result"])

  @spec default_options() :: options()
  def default_options, do: @default_options

  @spec turn_memories(map() | keyword(), map() | keyword() | nil) ::
          {:ok, [map()]} | {:skip, atom()}
  def turn_memories(params, opts \\ nil) do
    params = normalize_map(params)
    opts = normalize_options(opts)

    memories =
      params
      |> collect_segments()
      |> Enum.flat_map(&segment_memories(&1, params, opts))
      |> uniq_by_text()
      |> Enum.take(opts.max_memories_per_turn)

    case memories do
      [] -> {:skip, :not_durable}
      values -> {:ok, values}
    end
  end

  @spec signal_capture(struct(), map() | keyword() | nil) ::
          {:remember, [map()]} | {:skip, atom()}
  def signal_capture(signal, state \\ nil) do
    state = normalize_map(state)
    opts = normalize_options(Map.get(state, :memory_policy))
    rule = Map.get(state, :capture_rules, %{}) |> Map.get(signal.type, %{})
    data = normalize_map(signal.data)
    text = signal_text(data)
    base_tags = Enum.uniq(List.wrap(rule[:tags]) ++ ["signal:#{signal.type}", "memory:auto"])

    base_metadata =
      Map.merge(%{"signal_id" => signal.id, "signal_type" => signal.type}, rule[:metadata] || %{})

    base_attrs = %{
      content: data,
      metadata: base_metadata,
      observed_at: signal_time_ms(signal.time),
      source: rule[:source] || signal.source,
      tags: base_tags
    }

    cond do
      rule[:force_remember] ->
        attrs =
          base_attrs
          |> Map.merge(%{
            class: rule[:class] || :episodic,
            kind: rule[:kind] || infer_kind(signal.type),
            text: rule[:text] || text,
            persons: rule[:persons] || [],
            entities: rule[:entities] || []
          })

        {:remember, [attrs]}

      explicit_memory_signal?(signal.type) and opts.capture_explicit_memories ->
        remember_from_text(text, base_attrs, params_from_signal(data, :explicit_memory), opts)

      explicit_memory_text?(text) and opts.capture_explicit_memories ->
        remember_from_text(text, base_attrs, params_from_signal(data, :explicit_memory), opts)

      signal.type in @tool_result_types and opts.capture_tool_results and present_text?(text) ->
        attrs =
          Map.merge(base_attrs, %{
            class: :episodic,
            kind: :tool_result,
            text: ensure_sentence(text),
            persons: [],
            entities: [],
            topic: "tool result"
          })

        {:remember, [attrs]}

      query_signal?(signal.type) and opts.capture_queries and present_text?(text) ->
        attrs =
          Map.merge(base_attrs, %{
            class: :episodic,
            kind: :query,
            text: ensure_sentence(text),
            persons: [],
            entities: []
          })

        {:remember, [attrs]}

      response_signal?(signal.type) and opts.capture_responses and present_text?(text) ->
        attrs =
          Map.merge(base_attrs, %{
            class: :episodic,
            kind: :response,
            text: ensure_sentence(text),
            persons: [],
            entities: []
          })

        {:remember, [attrs]}

      true ->
        {:skip, :not_durable}
    end
  end

  defp remember_from_text(text, base_attrs, params, opts) do
    case turn_memories(Map.merge(params, %{text: text}), opts) do
      {:ok, memories} ->
        {:remember, Enum.map(memories, &Map.merge(base_attrs, &1))}

      {:skip, _reason} ->
        if present_text?(text) do
          {:remember,
           [
             Map.merge(base_attrs, %{
               class: :semantic,
               kind: :explicit_memory,
               text: ensure_sentence(strip_memory_prefix(text)),
               persons: [],
               entities: []
             })
           ]}
        else
          {:skip, :not_durable}
        end
    end
  end

  defp params_from_signal(data, source) do
    %{
      user_input: signal_text(data),
      metadata: %{"captured_from" => Atom.to_string(source)}
    }
  end

  defp collect_segments(params) do
    [
      {:user_input, Map.get(params, :user_input)},
      {:text, Map.get(params, :text)}
    ]
    |> Enum.reject(fn {_source, value} -> not present_text?(value) end)
  end

  defp segment_memories({source, text}, params, _opts) do
    text
    |> strip_memory_prefix()
    |> candidate_sentences()
    |> Enum.flat_map(fn sentence ->
      case classify_sentence(sentence, source) do
        nil ->
          []

        attrs ->
          [
            Map.merge(base_turn_attrs(source, params), attrs)
          ]
      end
    end)
  end

  defp base_turn_attrs(source, params) do
    %{
      tags:
        Enum.uniq(
          List.wrap(Map.get(params, :tags, [])) ++
            ["memory:auto", "turn:#{source}"]
        ),
      metadata:
        Map.merge(
          %{"policy" => "default", "captured_from" => Atom.to_string(source)},
          normalize_map(Map.get(params, :metadata))
        ),
      content:
        params
        |> Map.take([:user_input, :assistant_response, :text, :tool_results])
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
    }
  end

  defp classify_sentence(sentence, source) do
    condensed = String.trim(sentence)

    cond do
      condensed == "" ->
        nil

      match = Regex.run(~r/^my name is\s+(.+)$/i, condensed, capture: :all_but_first) ->
        semantic_fact("The user's name is #{trim_clause(hd(match))}.", :profile, [hd(match)])

      match = Regex.run(~r/^call me\s+(.+)$/i, condensed, capture: :all_but_first) ->
        semantic_fact("The user prefers to be called #{trim_clause(hd(match))}.", :profile, [
          hd(match)
        ])

      match = Regex.run(~r/^my pronouns are\s+(.+)$/i, condensed, capture: :all_but_first) ->
        semantic_fact("The user's pronouns are #{trim_clause(hd(match))}.", :profile)

      match = Regex.run(~r/^my birthday is\s+(.+)$/i, condensed, capture: :all_but_first) ->
        semantic_fact("The user's birthday is #{trim_clause(hd(match))}.", :profile)

      match =
          Regex.run(~r/^my favorite\s+(.+?)\s+is\s+(.+)$/i, condensed, capture: :all_but_first) ->
        semantic_fact(
          "The user's favorite #{trim_clause(Enum.at(match, 0))} is #{trim_clause(Enum.at(match, 1))}.",
          :preference
        )

      match =
          Regex.run(~r/^i (prefer|like|love|dislike|hate)\s+(.+)$/i, condensed,
            capture: :all_but_first
          ) ->
        verb = match |> Enum.at(0) |> String.downcase()
        value = match |> Enum.at(1) |> trim_clause()
        semantic_fact("The user #{verb}s #{value}.", :preference)

      match = Regex.run(~r/^i live in\s+(.+)$/i, condensed, capture: :all_but_first) ->
        semantic_fact("The user lives in #{trim_clause(hd(match))}.", :profile)

      match = Regex.run(~r/^i am based in\s+(.+)$/i, condensed, capture: :all_but_first) ->
        semantic_fact("The user is based in #{trim_clause(hd(match))}.", :profile)

      match = Regex.run(~r/^i am from\s+(.+)$/i, condensed, capture: :all_but_first) ->
        semantic_fact("The user is from #{trim_clause(hd(match))}.", :profile)

      match = Regex.run(~r/^i work at\s+(.+)$/i, condensed, capture: :all_but_first) ->
        semantic_fact("The user works at #{trim_clause(hd(match))}.", :profile)

      match = Regex.run(~r/^i work in\s+(.+)$/i, condensed, capture: :all_but_first) ->
        semantic_fact("The user works in #{trim_clause(hd(match))}.", :profile)

      match = Regex.run(~r/^i am allergic to\s+(.+)$/i, condensed, capture: :all_but_first) ->
        semantic_fact("The user is allergic to #{trim_clause(hd(match))}.", :constraint)

      match =
          Regex.run(~r/^i (?:can't|cannot|do not|don't) eat\s+(.+)$/i, condensed,
            capture: :all_but_first
          ) ->
        semantic_fact("The user cannot eat #{trim_clause(hd(match))}.", :constraint)

      source == :text and explicit_memory_text?(condensed) ->
        semantic_fact(ensure_sentence(strip_memory_prefix(condensed)), :explicit_memory)

      source == :text ->
        %{
          class: :semantic,
          kind: :turn_summary,
          text: ensure_sentence(condensed),
          persons: [],
          entities: []
        }

      true ->
        nil
    end
  end

  defp semantic_fact(text, kind, entities \\ []) do
    %{
      class: :semantic,
      kind: kind,
      text: ensure_sentence(text),
      persons: [],
      entities: Enum.map(entities, &trim_clause/1)
    }
  end

  defp candidate_sentences(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.split(~r/[.!?]+/u, trim: true)
    |> Enum.flat_map(fn sentence ->
      Regex.split(~r/\s+and\s+(?=(?:i\b|my\b|call me\b))/i, sentence, trim: true)
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp uniq_by_text(memories) do
    Enum.uniq_by(memories, &Map.get(&1, :text))
  end

  defp signal_text(data) do
    data[:query] || data[:text] || data[:content] || data[:result] || data[:output] ||
      if(map_size(data) == 0, do: nil, else: inspect(data))
  end

  defp infer_kind(type) do
    cond do
      query_signal?(type) -> :query
      response_signal?(type) -> :response
      String.ends_with?(type, ".result") -> :tool_result
      true -> :event
    end
  end

  defp explicit_memory_signal?(type), do: String.starts_with?(type, "memory.")
  defp query_signal?(type), do: String.ends_with?(type, ".query")
  defp response_signal?(type), do: String.ends_with?(type, ".response")

  defp explicit_memory_text?(text) when is_binary(text) do
    String.match?(text, ~r/^\s*(remember|please remember|note that|don't forget)\b/i)
  end

  defp explicit_memory_text?(_), do: false

  defp strip_memory_prefix(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.replace(
      ~r/^\s*(remember|please remember|note that|don't forget)(?:\s+that)?\s+/i,
      ""
    )
  end

  defp ensure_sentence(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" -> trimmed
      String.ends_with?(trimmed, ".") -> trimmed
      true -> trimmed <> "."
    end
  end

  defp trim_clause(value) do
    value
    |> String.trim()
    |> String.trim_trailing(".")
  end

  defp present_text?(value), do: is_binary(value) and String.trim(value) != ""

  defp normalize_options(nil), do: @default_options

  defp normalize_options(opts) when is_list(opts) do
    @default_options
    |> Map.merge(Map.new(opts))
  end

  defp normalize_options(%{} = opts) do
    Map.merge(@default_options, opts)
  end

  defp normalize_options(_), do: @default_options

  defp normalize_map(nil), do: %{}
  defp normalize_map(%{} = map), do: map
  defp normalize_map(list) when is_list(list), do: Map.new(list)
  defp normalize_map(_), do: %{}

  defp signal_time_ms(nil), do: System.system_time(:millisecond)

  defp signal_time_ms(time) when is_binary(time) do
    case DateTime.from_iso8601(time) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
      _ -> System.system_time(:millisecond)
    end
  end
end
