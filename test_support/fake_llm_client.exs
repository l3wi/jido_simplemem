defmodule Jido.SimpleMem.TestSupport.FakeLLMClient do
  @behaviour Jido.SimpleMem.LLMClient

  alias Jido.Memory.Record
  alias Jido.SimpleMem.{Dialogue, Tokenizer}

  @question_words MapSet.new(~w[who what when where why how does do did is are can should i me my we our])

  @impl true
  def extract_window(dialogues, previous_entries, _opts) do
    previous_texts = MapSet.new(Enum.map(previous_entries, &String.downcase(&1.restatement)))

    entries =
      dialogues
      |> Enum.flat_map(&extract_dialogue_entries/1)
      |> Enum.reject(fn entry ->
        MapSet.member?(previous_texts, String.downcase(entry["restatement"]))
      end)
      |> Enum.uniq_by(& &1["restatement"])

    {:ok, entries}
  end

  @impl true
  def synthesize(entries, previous_entries, _opts) do
    previous_texts = MapSet.new(Enum.map(previous_entries, &String.downcase(&1.restatement)))

    synthesized =
      entries
      |> Enum.reject(fn entry ->
        MapSet.member?(previous_texts, String.downcase(entry["restatement"] || ""))
      end)
      |> Enum.group_by(fn entry ->
        {
          Enum.sort(entry["persons"] || []),
          entry["topic"],
          entry["timestamp"],
          entry["location"]
        }
      end)
      |> Enum.flat_map(fn {_key, grouped} ->
        grouped
        |> Enum.uniq_by(& &1["restatement"])
        |> merge_related_entries()
      end)

    {:ok, synthesized}
  end

  @impl true
  def plan(%{question: question}, _opts) do
    persons = extract_people(question)
    location = extract_location(question)

    base_query = %{
      "query" => question,
      "keywords" => Tokenizer.keywords(question, limit: 8),
      "persons" => persons,
      "entities" => [],
      "location" => location
    }

    search_queries =
      [base_query] ++
        Enum.map(persons, fn person ->
          %{
            "query" => person,
            "keywords" => Tokenizer.keywords(person, limit: 4),
            "persons" => [person],
            "entities" => []
          }
        end)

    {:ok,
     %{
       "required_info" => [question],
       "search_queries" => Enum.uniq_by(search_queries, & &1["query"]),
       "keywords" => Tokenizer.keywords(question, limit: 8),
       "persons" => persons,
       "entities" => [],
       "location" => location,
       "time_expression" => if(String.match?(question, ~r/\bwhen\b/i), do: "time", else: nil),
       "question_type" => question_type(question)
     }}
  end

  @impl true
  def reflect(%{question: question}, records, _plan, _opts) do
    cond do
      records == [] ->
        {:ok, %{"status" => "no_results", "additional_queries" => [%{"query" => question}]}}

      String.match?(question, ~r/\bwhere\b/i) and
          Enum.all?(records, fn record -> not String.match?(record.text || "", ~r/\bin\b|\bat\b/i) end) ->
        {:ok,
         %{
           "status" => "incomplete",
           "additional_queries" => [%{"query" => question <> " location"}]
         }}

      String.match?(question, ~r/\bprefer|like|love|favorite\b/i) and
          Enum.all?(records, fn record ->
            not String.match?(record.text || "", ~r/\bprefer|like|love|favorite\b/i)
          end) ->
        {:ok,
         %{
           "status" => "incomplete",
           "additional_queries" => [%{"query" => question <> " preference"}]
         }}

      true ->
        {:ok, %{"status" => "complete", "additional_queries" => []}}
    end
  end

  @impl true
  def answer(%{question: question}, records, _opts) do
    people = extract_people(question)

    filtered_records =
      case people do
        [] ->
          records

        _ ->
          Enum.filter(records, fn %Record{} = record ->
            unit_people = get_in(record.metadata, ["simplemem", "persons"]) || []
            Enum.all?(people, &(&1 in unit_people))
          end)
      end

    if filtered_records == [] do
      {:ok,
       %{
         answer: "No relevant information found",
         reasoning: "No records matched the query.",
         confidence: 0.1,
         context: ""
       }}
    else
      top =
        Enum.max_by(filtered_records, fn %Record{} = record ->
          overlap = Tokenizer.overlap(Tokenizer.tokens(question), Tokenizer.tokens(record.text || ""))
          person_bonus = if Enum.any?(extract_people(question), &(&1 in (get_in(record.metadata, ["simplemem", "persons"]) || []))), do: 5, else: 0
          intent_bonus = intent_bonus(question, record.text || "")
          overlap + person_bonus + intent_bonus
        end)

      {:ok,
       %{
         answer: top.text,
         reasoning: "Selected the highest-overlap memory record.",
         confidence: 0.88,
         context: Enum.map_join(filtered_records, "\n", &("- " <> (&1.text || "")))
       }}
    end
  end

  defp extract_dialogue_entries(%Dialogue{content: content, speaker: speaker, timestamp: timestamp}) do
    text = String.trim(content)

    cond do
      text == "" ->
        []

      speaker == "assistant" and not String.match?(text, ~r/\bremember\b/i) ->
        []

      true ->
        text
        |> String.replace(~r/^\s*(remember|please remember|note that)\s+(that\s+)?/i, "")
        |> String.split(~r/[.!?]+/u, trim: true)
        |> Enum.flat_map(fn sentence ->
          sentence = String.trim(sentence)

          case statement_to_entries(sentence, timestamp) do
            [] ->
              sentence
              |> String.split(~r/\s+and\s+/i, trim: true)
              |> Enum.map(&String.trim/1)
              |> Enum.flat_map(&statement_to_entries(&1, timestamp))

            entries ->
              entries
          end
        end)
    end
  end

  defp statement_to_entries(sentence, timestamp) do
    people = extract_people(sentence)
    location = extract_location(sentence)

    cond do
      sentence == "" ->
        []

      match = Regex.run(~r/^my name is\s+(.+)$/i, sentence, capture: :all_but_first) ->
        [entry("The user's name is #{trim(hd(match))}.", [], nil, timestamp, "profile")]

      match = Regex.run(~r/^i live in\s+(.+)$/i, sentence, capture: :all_but_first) ->
        loc = trim(hd(match))
        [entry("The user lives in #{loc}.", [], loc, timestamp, "profile")]

      match = Regex.run(~r/^i prefer\s+(.+)$/i, sentence, capture: :all_but_first) ->
        [entry("The user prefers #{trim(hd(match))}.", [], nil, timestamp, "preference")]

      match = Regex.run(~r/^i am allergic to\s+(.+)$/i, sentence, capture: :all_but_first) ->
        [entry("The user is allergic to #{trim(hd(match))}.", [], nil, timestamp, "constraint")]

      length(people) > 0 and String.match?(sentence, ~r/\bprefer|likes?|loves?|favorite\b/i) ->
        [entry(ensure_sentence(sentence), people, location, timestamp, "profile")]

      length(people) > 0 and String.match?(sentence, ~r/\blives in|works in|works at|based in|from\b/i) ->
        [entry(ensure_sentence(sentence), people, location, timestamp, "profile")]

      String.match?(sentence, ~r/\bmeet\b/i) ->
        [entry(ensure_sentence(sentence), people, location, timestamp, "event")]

      true ->
        []
    end
  end

  defp entry(restatement, persons, location, timestamp, topic) do
    %{
      "restatement" => ensure_sentence(restatement),
      "text" => ensure_sentence(restatement),
      "persons" => persons,
      "entities" => [],
      "location" => location,
      "topic" => topic,
      "timestamp" => timestamp,
      "metadata" => %{}
    }
  end

  defp merge_related_entries([single]), do: [single]

  defp merge_related_entries(entries) do
    combined_text =
      entries
      |> Enum.map(&(&1["restatement"] || ""))
      |> Enum.uniq()
      |> Enum.join(" ")
      |> ensure_sentence()

    [Map.merge(hd(entries), %{"restatement" => combined_text, "text" => combined_text})]
  end

  defp extract_people(text) do
    ~r/\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?\b/u
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.reject(&(String.downcase(&1) in @question_words))
    |> Enum.uniq()
  end

  defp extract_location(text) do
    case Regex.run(~r/\b(?:in|at|from|based in)\s+([A-Z][\w-]*(?:\s+[A-Z][\w-]*)*)/u, text,
           capture: :all_but_first
         ) do
      [location] -> trim(location)
      _ -> nil
    end
  end

  defp question_type(question) do
    cond do
      String.match?(question, ~r/\bwhen\b/i) -> "temporal"
      String.match?(question, ~r/\bwho\b/i) -> "entity"
      String.match?(question, ~r/\bwhy\b|\bhow\b/i) -> "multi_hop"
      true -> "factual"
    end
  end

  defp ensure_sentence(text) do
    trimmed = trim(text)
    if String.ends_with?(trimmed, "."), do: trimmed, else: trimmed <> "."
  end

  defp intent_bonus(question, text) do
    cond do
      String.match?(question, ~r/\bprefer|like|love|favorite\b/i) and
          String.match?(text, ~r/\bprefer|like|love|favorite\b/i) ->
        5

      String.match?(question, ~r/\bwhere\b/i) and String.match?(text, ~r/\blives in|works in|works at|based in|from\b/i) ->
        5

      String.match?(question, ~r/\bname\b/i) and String.match?(text, ~r/\bname\b/i) ->
        5

      true ->
        0
    end
  end

  defp trim(value), do: value |> String.trim() |> String.trim_trailing(".")
end
