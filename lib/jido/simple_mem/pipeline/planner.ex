defmodule Jido.SimpleMem.Planner do
  @moduledoc false

  alias Jido.SimpleMem.{EmbeddingVector, Tokenizer}

  @spec plan(map(), map()) :: {:ok, map()} | {:error, term()}
  def plan(query, runtime) when is_map(query) do
    question =
      Map.get(query, :question) || Map.get(query, "question") || Map.get(query, :text_contains) ||
        Map.get(query, "text_contains") || ""

    with {:ok, llm_plan} <- runtime.llm_client.plan(%{question: question}, runtime.llm_opts) do
      limit = Map.get(query, :limit) || Map.get(query, "limit") || runtime.retrieval_limit

      with {:ok, search_queries} <-
             llm_plan
             |> search_queries(question)
             |> normalize_subqueries(runtime) do
        {:ok,
         %{
           question: question,
           required_info: llm_plan[:required_info] || llm_plan["required_info"] || [],
           search_queries: search_queries,
           keywords: normalize_list(llm_plan[:keywords] || llm_plan["keywords"] || []),
           persons: normalize_list(llm_plan[:persons] || llm_plan["persons"] || []),
           entities: normalize_list(llm_plan[:entities] || llm_plan["entities"] || []),
           location: llm_plan[:location] || llm_plan["location"],
           time_expression: llm_plan[:time_expression] || llm_plan["time_expression"],
           question_type:
             normalize_question_type(llm_plan[:question_type] || llm_plan["question_type"]),
           limit: limit,
           fetch_limit: max(limit * 3, 25),
           reflection_enabled: Map.get(query, :reflection_enabled, runtime.reflection_enabled),
           max_reflection_rounds:
             Map.get(query, :max_reflection_rounds, runtime.max_reflection_rounds),
           now: runtime.now
         }}
      end
    end
  end

  defp search_queries(llm_plan, question) do
    llm_value = llm_plan[:search_queries] || llm_plan["search_queries"] || []

    case llm_value do
      [] -> [%{"query" => question}]
      list when is_list(list) -> list
      _ -> [%{"query" => question}]
    end
  end

  defp normalize_subqueries(queries, runtime) when is_list(queries) do
    Enum.reduce_while(queries, {:ok, []}, fn query, {:ok, acc} ->
      case normalize_subquery(query, runtime) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_subquery(query, runtime) do
    query_map =
      case query do
        %{} = map -> map
        binary when is_binary(binary) -> %{"query" => binary}
        other -> %{"query" => to_string(other)}
      end

    query_text = query_map[:query] || query_map["query"] || ""

    with {:ok, query_embedding} <- embed(query_text, runtime) do
      {:ok,
       %{
         query: query_text,
         keywords:
           normalize_list(
             query_map[:keywords] || query_map["keywords"] || Tokenizer.keywords(query_text)
           ),
         persons: normalize_list(query_map[:persons] || query_map["persons"] || []),
         entities: normalize_list(query_map[:entities] || query_map["entities"] || []),
         location: query_map[:location] || query_map["location"],
         time_expression:
           query_map[:time_expression] || query_map["time_expression"] ||
             query_map[:timestamp_hint] || query_map["timestamp_hint"],
         query_embedding: query_embedding
       }}
    end
  end

  defp embed("", _runtime), do: {:ok, []}

  defp embed(text, runtime) do
    case runtime.embedding_client.embed(text, runtime.embedding_opts) do
      {:ok, vector} ->
        case EmbeddingVector.validate(vector, runtime, :query_embedding) do
          :ok -> {:ok, vector}
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error

      other ->
        {:error, other}
    end
  end

  defp normalize_question_type(value) when is_binary(value) do
    case String.trim(value) do
      "factual" -> :factual
      "temporal" -> :temporal
      "entity" -> :entity
      "multi_hop" -> :multi_hop
      _ -> :factual
    end
  end

  defp normalize_question_type(value) when value in [:factual, :temporal, :entity, :multi_hop],
    do: value

  defp normalize_question_type(_), do: :factual

  defp normalize_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp normalize_list(nil), do: []
  defp normalize_list(value), do: [to_string(value)]
end
