defmodule Jido.SimpleMem.Answerer do
  @moduledoc false

  @question_words MapSet.new(~w[who what when where why how does do did is are can should])

  @spec answer(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def answer(question, explain, runtime) do
    case maybe_llm_answer(question, explain.records, runtime) do
      {:ok, response} ->
        {:ok, response}

      _ ->
        {:ok, heuristic_answer(question, explain.records, runtime.context_token_budget)}
    end
  end

  defp maybe_llm_answer(question, records, runtime) do
    if function_exported?(runtime.llm_client, :answer, 3) do
      runtime.llm_client.answer(question, records, runtime.llm_opts)
    else
      {:error, :not_implemented}
    end
  end

  defp heuristic_answer(_question, [], _budget) do
    %{
      answer: "No relevant memory found.",
      confidence: 0.1,
      reasoning: "No records matched the query.",
      context: ""
    }
  end

  defp heuristic_answer(question, records, budget) do
    top = select_focus_record(question, records)
    memory = top.metadata["simplemem"] || %{}
    focused_records = prioritize_records(top, records)

    answer =
      cond do
        String.match?(Map.get(question, :question, ""), ~r/\bwhen\b/i) and
            is_binary(memory["timestamp"]) ->
          "#{top.text} (time: #{memory["timestamp"]})"

        String.match?(Map.get(question, :question, ""), ~r/\bwhere\b/i) and
            is_binary(memory["location"]) ->
          "#{top.text} (location: #{memory["location"]})"

        true ->
          Enum.take(focused_records, 1) |> Enum.map_join(" ", &(&1.text || ""))
      end

    %{
      answer: answer,
      confidence: min(0.99, 0.45 + length(records) * 0.1),
      reasoning: "Generated from ranked SimpleMem records.",
      context: Jido.SimpleMem.build_context(focused_records, budget)
    }
  end

  defp select_focus_record(question, records) do
    requested_people = question_people(Map.get(question, :question, ""))

    Enum.find(records, hd(records), fn record ->
      record_people = record.metadata["simplemem"]["persons"] || []
      requested_people != [] and Enum.all?(requested_people, &(&1 in record_people))
    end)
  end

  defp prioritize_records(top, records) do
    [top | Enum.reject(records, &(&1.id == top.id))]
  end

  defp question_people(question) when is_binary(question) do
    ~r/\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?\b/u
    |> Regex.scan(question)
    |> List.flatten()
    |> Enum.reject(&(String.downcase(&1) in @question_words))
    |> Enum.uniq()
  end
end
