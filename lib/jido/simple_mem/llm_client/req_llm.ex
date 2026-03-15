defmodule Jido.SimpleMem.LLMClient.ReqLLM do
  @moduledoc false

  @behaviour Jido.SimpleMem.LLMClient

  alias Jido.Memory.Record
  alias Jido.SimpleMem.Dialogue

  @impl true
  def extract_window(dialogues, previous_entries, opts) when is_list(dialogues) do
    model = fetch_model!(opts, :extraction_model)

    prompt = """
    You are implementing SimpleMem Stage 1: semantic structured compression.

    Given the dialogue window below, extract all valuable information and convert
    it into structured memory entries.

    Requirements:
    - Apply implicit semantic density gating: omit low-value chatter, filler, and acknowledgements.
    - Preserve complete informative coverage from the window.
    - If the user explicitly asks to remember, store, note, or keep information, you must extract that information.
    - Stable user facts such as identity, preferences, location, constraints, relationships, and durable plans must be extracted.
    - Direct factual statements about named people, locations, preferences, work, identity, or relationships must be extracted.
    - Never return an empty array when the window contains explicit profile facts, preference facts, location facts, or "remember this" instructions.
    - Output self-contained, standalone memory entries.
    - Resolve pronouns and coreference fully.
    - Convert relative time references into absolute ISO 8601 timestamps whenever the window allows it.
    - Split multi-fact windows into multiple entries when needed.
    - Avoid duplicating previous-window memory entries unless the new window materially extends them.
    - Prefer compact, information-dense restatements suitable for long-term retrieval.
    - Return an empty array only when the dialogue contains no durable or informative memory-worthy content at all.

    Previous window memory entries:
    #{format_previous_entries(previous_entries)}

    Dialogue window:
    #{Enum.map_join(dialogues, "\n", &Dialogue.to_prompt_line/1)}

    Return JSON with an `entries` array. Each entry must include:
    - restatement
    - keywords
    - timestamp
    - location
    - persons
    - entities
    - topic
    When a field is unknown, use an empty string for scalar fields and an empty list for array fields.

    Example durable facts that must produce entries:
    - "Morgan Lee lives in Denver and prefers pour-over coffee."
    - "The user is allergic to peanuts."
    - "Remember that Priya Sharma works remotely from Berlin."
    """

    result =
      model
      |> ReqLLM.generate_text!(
        prompt <> extraction_json_contract(),
        Keyword.merge(request_opts(opts), temperature: 1.0)
      )
      |> decode_json_object!()

    {:ok, normalize_entries(result["entries"] || result[:entries] || [])}
  rescue
    error -> {:error, error}
  end

  @impl true
  def synthesize(entries, previous_entries, opts) when is_list(entries) do
    model = fetch_model!(opts, :synthesis_model)

    prompt = """
    You are implementing SimpleMem Stage 2: online semantic synthesis.

    You will receive newly extracted memory entries for the current dialogue
    window and recent prior session entries. Produce a synthesized set of memory
    entries that:
    - preserves all informative content
    - merges semantically overlapping fragments when they describe the same fact
    - does not collapse distinct people, distinct events, or distinct timestamps
    - keeps entries self-contained and retrieval-friendly
    - prefers one higher-density entry over several redundant fragments when no information is lost

    Recent prior session entries:
    #{format_previous_entries(previous_entries)}

    Newly extracted entries:
    #{format_entries(entries)}

    Return JSON with an `entries` array using the same entry schema as extraction.
    Every field must be present. Use empty strings or empty lists when needed.
    """

    result =
      model
      |> ReqLLM.generate_text!(
        prompt <> extraction_json_contract(),
        Keyword.merge(request_opts(opts), temperature: 1.0)
      )
      |> decode_json_object!()

    synthesized = normalize_entries(result[:entries] || result["entries"] || [])

    {:ok, synthesized}
  rescue
    error -> {:error, error}
  end

  @impl true
  def plan(query, opts) when is_map(query) do
    model = fetch_model!(opts, :planning_model)

    question =
      query[:question] || query["question"] || query[:text_contains] || query["text_contains"] ||
        ""

    prompt = """
    You are implementing SimpleMem Stage 3: intent-aware retrieval planning.

    Analyze the user question and produce a hybrid retrieval plan.

    Requirements:
    - identify the minimum required information needed to answer the question
    - generate targeted semantic subqueries for conceptual retrieval
    - extract lexical terms for keyword search
    - extract symbolic filters for persons, entities, location, and time expressions
    - classify the question type as factual, temporal, entity, or multi_hop
    - prefer a small number of high-value semantic subqueries
    - include the original question if it is already a good semantic query
    - all fields in the output must be present; use empty strings or empty lists when unknown

    Question:
    #{question}
    """

    schema = [
      required_info: [type: {:list, :string}, required: true],
      search_queries: [type: {:list, query_schema()}, required: true],
      keywords: [type: {:list, :string}, required: true],
      persons: [type: {:list, :string}, required: false],
      entities: [type: {:list, :string}, required: false],
      location: [type: :string, required: false],
      time_expression: [type: :string, required: false],
      question_type: [
        type: {:in, ["factual", "temporal", "entity", "multi_hop"]},
        required: true
      ]
    ]

    {:ok,
     query_plan(
       ReqLLM.generate_object!(model, prompt, schema, Keyword.merge(request_opts(opts), temperature: 1.0))
     )}
  rescue
    error -> {:error, error}
  end

  @impl true
  def reflect(question, records, plan, opts) when is_map(question) and is_list(records) do
    model = fetch_model!(opts, :planning_model)

    prompt = """
    You are SimpleMem's intelligent reflection step.

    Determine whether the retrieved context completely answers the question given
    the required information types. If it does not, generate additional targeted
    semantic subqueries for the missing information.

    Question:
    #{question[:question] || question["question"] || ""}

    Planned required info:
    #{Enum.map_join(plan[:required_info] || plan["required_info"] || [], "\n", &("- " <> &1))}

    Retrieved context:
    #{format_records(records)}

    All fields in the output must be present. Use empty strings or empty lists when unknown.
    """

    schema = [
      status: [type: {:in, ["complete", "incomplete", "no_results"]}, required: true],
      reasoning: [type: :string, required: false],
      missing_info: [type: {:list, :string}, required: false],
      additional_queries: [type: {:list, query_schema()}, required: false]
    ]

    {:ok,
     reflection_result(
       ReqLLM.generate_object!(model, prompt, schema, Keyword.merge(request_opts(opts), temperature: 1.0))
     )}
  rescue
    error -> {:error, error}
  end

  @impl true
  def answer(question, records, opts) when is_map(question) and is_list(records) do
    model = fetch_model!(opts, :answer_model)

    prompt = """
    You are implementing SimpleMem's answer generation stage.

    Answer the user's question using only the provided memory context.

    Requirements:
    - use only the supplied memory entries
    - do not invent missing facts
    - keep the final answer concise
    - format dates in readable natural language
    - include short reasoning and confidence
    - if the context is insufficient, say so explicitly in the answer instead of guessing

    Question:
    #{question[:question] || question["question"] || ""}

    Memory context:
    #{format_records(records)}
    """

    object =
      model
      |> ReqLLM.generate_text!(
        prompt <> answer_json_contract(),
        Keyword.merge(request_opts(opts), temperature: 1.0)
      )
      |> decode_json_object!()

    {:ok,
     %{
       reasoning: object[:reasoning] || object["reasoning"],
       answer: object[:answer] || object["answer"],
       confidence: object[:confidence] || object["confidence"],
       context: format_records(records)
     }}
  rescue
    error -> {:error, error}
  end

  defp fetch_model!(opts, key) do
    model =
      Keyword.get(opts, key) ||
        Keyword.get(opts, :model) ||
        raise ReqLLM.Error.Invalid.Parameter.exception(parameter: "LLM model required for #{key}")

    {:ok, validated} = ReqLLM.model(model)
    ensure_provider_auth!(validated.provider, opts)
    model
  end

  defp ensure_provider_auth!(provider, opts) do
    case Keyword.get(opts, :api_key) do
      value when is_binary(value) and value != "" ->
        :ok

      _ ->
        env_var = ReqLLM.Keys.env_var_name(provider)

        case System.get_env(env_var) do
          value when is_binary(value) and value != "" ->
            :ok

          _ ->
            raise ReqLLM.Error.Invalid.Parameter.exception(
                    parameter: "provider API key required via :api_key option or env var: #{env_var}"
                  )
        end
    end
  end

  defp normalize_entries(entries) do
    Enum.map(entries, fn
      %{} = entry -> normalize_entry(entry)
      other -> normalize_entry(%{"restatement" => to_string(other)})
    end)
  end

  defp query_schema do
    {:map,
     [
       query: [type: :string, required: true],
       keywords: [type: {:list, :string}, required: true],
       persons: [type: {:list, :string}, required: true],
       entities: [type: {:list, :string}, required: true],
       location: [type: :string, required: true],
       time_expression: [type: :string, required: true]
     ]}
  end

  defp format_previous_entries([]), do: "None"

  defp format_previous_entries(entries) do
    Enum.map_join(entries, "\n", fn entry ->
      "- #{entry.restatement}"
    end)
  end

  defp format_entries(entries) do
    Enum.map_join(entries, "\n", fn entry ->
      inspect(entry)
    end)
  end

  defp format_records([]), do: "No records."

  defp format_records(records) do
    Enum.map_join(records, "\n\n", fn
      %Record{} = record ->
        """
        Content: #{record.text}
        Timestamp: #{get_in(record.metadata, ["simplemem", "timestamp"]) || "n/a"}
        Location: #{get_in(record.metadata, ["simplemem", "location"]) || "n/a"}
        Persons: #{Enum.join(get_in(record.metadata, ["simplemem", "persons"]) || [], ", ")}
        Entities: #{Enum.join(get_in(record.metadata, ["simplemem", "entities"]) || [], ", ")}
        """

      other ->
        inspect(other)
    end)
  end

  defp extraction_json_contract do
    """

    Return only valid JSON. No markdown fences. No explanation. Return exactly:
    {
      "entries": [
        {
          "restatement": "standalone memory sentence",
          "keywords": ["keyword"],
          "timestamp": "",
          "location": "",
          "persons": ["Person Name"],
          "entities": [],
          "topic": "profile"
        }
      ]
    }
    """
  end

  defp answer_json_contract do
    """

    Return only valid JSON. No markdown fences. No explanation. Return exactly:
    {
      "reasoning": "brief grounded reasoning",
      "answer": "concise answer based only on the provided memory context",
      "confidence": 0.0
    }
    """
  end

  defp normalize_entry(entry) do
    %{
      "restatement" => string_or_nil(entry["restatement"] || entry[:restatement]),
      "keywords" => list_of_strings(entry["keywords"] || entry[:keywords]),
      "timestamp" => string_or_nil(entry["timestamp"] || entry[:timestamp]),
      "location" => string_or_nil(entry["location"] || entry[:location]),
      "persons" => list_of_strings(entry["persons"] || entry[:persons]),
      "entities" => list_of_strings(entry["entities"] || entry[:entities]),
      "topic" => string_or_nil(entry["topic"] || entry[:topic])
    }
  end

  defp query_plan(result) do
    %{
      "required_info" => list_of_strings(result["required_info"] || result[:required_info]),
      "search_queries" =>
        Enum.map(result["search_queries"] || result[:search_queries] || [], &normalize_query/1),
      "keywords" => list_of_strings(result["keywords"] || result[:keywords]),
      "persons" => list_of_strings(result["persons"] || result[:persons]),
      "entities" => list_of_strings(result["entities"] || result[:entities]),
      "location" => string_or_nil(result["location"] || result[:location]),
      "time_expression" => string_or_nil(result["time_expression"] || result[:time_expression]),
      "question_type" => result["question_type"] || result[:question_type]
    }
  end

  defp reflection_result(result) do
    %{
      "status" => result["status"] || result[:status],
      "reasoning" => string_or_nil(result["reasoning"] || result[:reasoning]),
      "missing_info" => list_of_strings(result["missing_info"] || result[:missing_info]),
      "additional_queries" =>
        Enum.map(
          result["additional_queries"] || result[:additional_queries] || [],
          &normalize_query/1
        )
    }
  end

  defp normalize_query(query) do
    %{
      "query" => query["query"] || query[:query] || "",
      "keywords" => list_of_strings(query["keywords"] || query[:keywords]),
      "persons" => list_of_strings(query["persons"] || query[:persons]),
      "entities" => list_of_strings(query["entities"] || query[:entities]),
      "location" => string_or_nil(query["location"] || query[:location]),
      "time_expression" => string_or_nil(query["time_expression"] || query[:time_expression])
    }
  end

  defp string_or_nil(nil), do: nil
  defp string_or_nil(""), do: nil
  defp string_or_nil(value) when is_binary(value), do: String.trim(value) |> empty_to_nil()
  defp string_or_nil(value), do: value |> to_string() |> String.trim() |> empty_to_nil()

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp list_of_strings(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp list_of_strings(nil), do: []
  defp list_of_strings(value), do: [to_string(value)]

  defp request_opts(opts) do
    opts
    |> Keyword.take([
      :api_key,
      :provider_options,
      :req_http_options,
      :receive_timeout,
      :max_tokens,
      :max_completion_tokens
    ])
  end

  defp decode_json_object!(text) when is_binary(text) do
    normalized =
      text
      |> String.trim()
      |> String.replace(~r/^```json\s*/i, "")
      |> String.replace(~r/^```\s*/, "")
      |> String.replace(~r/\s*```$/, "")

    case Jason.decode(normalized) do
      {:ok, decoded} ->
        decoded

      {:error, _reason} ->
        normalized
        |> extract_json_object()
        |> Jason.decode!()
    end
  end

  defp extract_json_object(text) do
    start_index =
      case :binary.match(text, "{") do
        :nomatch -> nil
        {index, _length} -> index
      end

    end_index =
      case :binary.matches(text, "}") do
        [] -> nil
        matches -> matches |> List.last() |> elem(0)
      end

    if is_integer(start_index) and is_integer(end_index) and end_index >= start_index do
      String.slice(text, start_index, end_index - start_index + 1)
    else
      raise "no JSON object found in model output"
    end
  end
end
