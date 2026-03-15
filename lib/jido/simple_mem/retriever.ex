defmodule Jido.SimpleMem.Retriever do
  @moduledoc false

  alias Jido.SimpleMem.{EmbeddingVector, Mapper}

  @spec retrieve(map(), map()) :: {:ok, map()} | {:error, term()}
  def retrieve(plan, runtime) do
    with {:ok, initial} <- retrieve_queries(plan.search_queries, plan, runtime),
         merged <- merge_candidates(initial.candidates),
         {:ok, reflected} <- maybe_reflect(plan, merged, initial.traces, runtime) do
      {:ok, reflected}
    end
  end

  @spec select(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def select(retrieval, plan, _runtime) do
    ordered =
      retrieval.candidates
      |> Enum.sort_by(&sort_key/1)

    {:ok, %{candidates: ordered, selected: Enum.take(ordered, plan.limit || 10)}}
  end

  defp retrieve_queries(search_queries, plan, runtime) do
    traces =
      run_queries(search_queries, plan, runtime)
      |> Enum.map(fn %{query: query, candidates: candidates} = trace ->
        Map.put(trace, :candidate_count, length(candidates))
        |> Map.put(:query, query)
      end)

    {:ok, %{candidates: Enum.flat_map(traces, & &1.candidates), traces: traces, reflections: []}}
  end

  defp run_queries(search_queries, plan, runtime) do
    if runtime.enable_parallel_retrieval and length(search_queries) > 1 do
      search_queries
      |> Task.async_stream(&run_single_query(&1, plan, runtime),
        ordered: true,
        timeout: 30_000,
        max_concurrency: runtime.max_retrieval_workers
      )
      |> Enum.map(fn {:ok, trace} -> trace end)
    else
      Enum.map(search_queries, &run_single_query(&1, plan, runtime))
    end
  end

  defp run_single_query(subquery, plan, runtime) do
    channel_plan =
      %{
        keywords: subquery.keywords,
        persons: subquery.persons,
        entities: subquery.entities,
        location: subquery.location,
        time_expression: subquery.time_expression || plan.time_expression,
        query_embedding: subquery.query_embedding,
        since: plan[:since],
        until: plan[:until],
        classes: plan[:classes] || [],
        kinds: plan[:kinds] || [],
        tags_any: plan[:tags_any] || [],
        tags_all: plan[:tags_all] || [],
        limit: plan.limit,
        fetch_limit: plan.fetch_limit,
        now: plan.now
      }

    {:ok, candidates} =
      runtime.store_mod.search(runtime.namespace, channel_plan, runtime.store_opts)

    %{query: subquery.query, plan: channel_plan, candidates: candidates}
  end

  defp maybe_reflect(plan, candidates, traces, runtime) do
    if plan.reflection_enabled do
      do_reflect(plan, candidates, traces, runtime, 0, [])
    else
      {:ok, %{candidates: candidates, traces: traces, reflections: []}}
    end
  end

  defp do_reflect(plan, candidates, traces, _runtime, round, reflections)
       when round >= plan.max_reflection_rounds do
    {:ok, %{candidates: candidates, traces: traces, reflections: Enum.reverse(reflections)}}
  end

  defp do_reflect(plan, candidates, traces, runtime, round, reflections) do
    records = candidates_to_records(candidates, plan)

    with {:ok, reflection} <-
           runtime.llm_client.reflect(%{question: plan.question}, records, plan, runtime.llm_opts) do
      status = to_string(reflection[:status] || reflection["status"] || "complete")

      case status do
        "incomplete" ->
          additional_queries =
            reflection[:additional_queries] || reflection["additional_queries"] || []

          with {:ok, normalized_queries} <-
                 normalize_additional_queries(additional_queries, runtime) do
            more_traces = run_queries(normalized_queries, plan, runtime)
            merged = merge_candidates(candidates ++ Enum.flat_map(more_traces, & &1.candidates))

            do_reflect(
              plan,
              merged,
              traces ++ more_traces,
              runtime,
              round + 1,
              [%{status: status, queries: normalized_queries} | reflections]
            )
          end

        _ ->
          {:ok,
           %{
             candidates: candidates,
             traces: traces,
             reflections: Enum.reverse([%{status: status} | reflections])
           }}
      end
    end
  end

  defp merge_candidates(candidates) do
    candidates
    |> Enum.reduce(%{}, fn candidate, acc ->
      Map.update(acc, candidate.unit.id, candidate, fn existing ->
        %{
          unit:
            if(candidate.unit.observed_at >= existing.unit.observed_at,
              do: candidate.unit,
              else: existing.unit
            ),
          lexical_score: max(candidate.lexical_score, existing.lexical_score),
          semantic_score: max(candidate.semantic_score, existing.semantic_score),
          symbolic_score: max(candidate.symbolic_score, existing.symbolic_score),
          recency_score: max(candidate.recency_score, existing.recency_score),
          channels: Enum.uniq((candidate.channels || []) ++ (existing.channels || [])),
          lexical_rank: best_rank(existing.lexical_rank, candidate.lexical_rank),
          semantic_rank: best_rank(existing.semantic_rank, candidate.semantic_rank),
          structured_rank: best_rank(existing.structured_rank, candidate.structured_rank)
        }
      end)
    end)
    |> Map.values()
  end

  defp candidates_to_records(candidates, plan) do
    candidates
    |> Enum.sort_by(fn candidate ->
      -(candidate.lexical_score + candidate.semantic_score + candidate.symbolic_score +
          candidate.recency_score)
    end)
    |> Enum.take(plan.fetch_limit || plan.limit || 10)
    |> Enum.map(&Mapper.to_record(&1.unit))
  end

  defp normalize_additional_queries(queries, runtime) when is_list(queries) do
    Enum.reduce_while(queries, {:ok, []}, fn query, {:ok, acc} ->
      case normalize_additional_query(query, runtime) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_additional_query(query, runtime) do
    query_map = if is_map(query), do: query, else: %{"query" => to_string(query)}
    query_text = query_map[:query] || query_map["query"] || ""

    with {:ok, query_embedding} <- embed_query(query_text, runtime) do
      {:ok,
       %{
         query: query_text,
         keywords: normalize_list(query_map[:keywords] || query_map["keywords"] || []),
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

  defp embed_query("", _runtime), do: {:ok, []}

  defp embed_query(query_text, runtime) do
    case runtime.embedding_client.embed(query_text, runtime.embedding_opts) do
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

  defp normalize_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp normalize_list(nil), do: []
  defp normalize_list(value), do: [to_string(value)]

  defp best_rank(nil, rank), do: rank
  defp best_rank(rank, nil), do: rank
  defp best_rank(left, right), do: min(left, right)

  defp sort_key(candidate) do
    {
      source_priority(candidate),
      candidate.structured_rank || 9_999,
      candidate.semantic_rank || 9_999,
      candidate.lexical_rank || 9_999,
      -(candidate.symbolic_score + candidate.semantic_score + candidate.lexical_score),
      -candidate.recency_score,
      -(candidate.unit.observed_at || 0)
    }
  end

  defp source_priority(candidate) do
    cond do
      :structured in (candidate.channels || []) -> 0
      :semantic in (candidate.channels || []) -> 1
      :keyword in (candidate.channels || []) -> 2
      true -> 3
    end
  end
end
