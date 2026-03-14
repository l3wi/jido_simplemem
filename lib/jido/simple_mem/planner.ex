defmodule Jido.SimpleMem.Planner do
  @moduledoc false

  alias Jido.SimpleMem.Tokenizer

  @question_words MapSet.new(~w[who what when where why how does do did is are can should])

  @spec plan(map(), map()) :: {:ok, map()} | {:error, term()}
  def plan(query, runtime) when is_map(query) do
    llm_plan = maybe_llm_plan(query, runtime)

    question =
      Map.get(query, :question) || Map.get(query, "question") || Map.get(query, :text_contains) ||
        Map.get(query, "text_contains") || ""

    keywords =
      llm_plan[:keywords] || llm_plan["keywords"] || Tokenizer.keywords(question, limit: 10)

    query_embedding = embed(question, runtime)

    {:ok,
     %{
       question: question,
       classes: Map.get(query, :classes, []),
       kinds: Map.get(query, :kinds, []),
       tags_any: normalize_list(Map.get(query, :tags_any, [])),
       tags_all: normalize_list(Map.get(query, :tags_all, [])),
       since: Map.get(query, :since),
       until: Map.get(query, :until),
       limit: Map.get(query, :limit, runtime.retrieval_limit),
       order: Map.get(query, :order, :desc),
       debug: Map.get(query, :debug, false),
       reflection_enabled: Map.get(query, :reflection_enabled, runtime.reflection_enabled),
       max_reflection_rounds:
         Map.get(query, :max_reflection_rounds, runtime.max_reflection_rounds),
       keywords: Enum.uniq(Enum.map(keywords, &to_string/1)),
       persons: persons(question, llm_plan),
       entities: normalize_list(llm_plan[:entities] || llm_plan["entities"] || []),
       location: llm_plan[:location] || llm_plan["location"],
       timestamp_hint: llm_plan[:timestamp] || llm_plan["timestamp"],
       question_type: classify_question(question),
       query_embedding: query_embedding,
       now: runtime.now
     }}
  end

  defp maybe_llm_plan(query, runtime) do
    if function_exported?(runtime.llm_client, :plan, 2) do
      case runtime.llm_client.plan(query, runtime.llm_opts) do
        {:ok, result} when is_map(result) -> result
        _ -> %{}
      end
    else
      %{}
    end
  end

  defp persons(question, llm_plan) do
    llm_value = llm_plan[:persons] || llm_plan["persons"] || []

    if llm_value != [] do
      normalize_list(llm_value)
    else
      ~r/\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?\b/u
      |> Regex.scan(question)
      |> List.flatten()
      |> Enum.reject(&(String.downcase(&1) in @question_words))
      |> Enum.uniq()
    end
  end

  defp classify_question(question) do
    cond do
      String.match?(question, ~r/\bwhen\b/i) -> :temporal
      String.match?(question, ~r/\bwho\b/i) -> :entity
      String.match?(question, ~r/\bwhy\b|\bhow\b/i) -> :multi_hop
      true -> :factual
    end
  end

  defp embed("", _runtime), do: []

  defp embed(question, runtime) do
    case runtime.embedding_client.embed(question, runtime.embedding_opts) do
      {:ok, vector} -> vector
      _ -> []
    end
  end

  defp normalize_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp normalize_list(nil), do: []
  defp normalize_list(value), do: [to_string(value)]
end
