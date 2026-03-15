defmodule Jido.SimpleMem.Explainer do
  @moduledoc false

  @spec explain(map()) :: map()
  def explain(%{
        query: query,
        plan: plan,
        runtime: runtime,
        ranked: ranked,
        retrieval: retrieval,
        records: records
      }) do
    %{
      query: query,
      plan: Map.drop(plan, [:query_embedding]),
      records: records,
      retrieval_traces: retrieval.traces,
      reflection_rounds: retrieval.reflections,
      scored_candidates:
        Enum.map(ranked.candidates, fn candidate ->
          %{
            id: candidate.unit.id,
            restatement: candidate.unit.restatement,
            channels: candidate.channels,
            lexical_rank: candidate.lexical_rank,
            semantic_rank: candidate.semantic_rank,
            structured_rank: candidate.structured_rank,
            semantic_score: candidate.semantic_score,
            lexical_score: candidate.lexical_score,
            symbolic_score: candidate.symbolic_score,
            recency_score: candidate.recency_score
          }
        end),
      selected_ids: Enum.map(ranked.selected, & &1.unit.id),
      context_pack: Jido.SimpleMem.build_context(records, runtime.context_token_budget),
      decision_trace: %{
        question_type: plan.question_type,
        limit: plan.limit,
        reflection_enabled: plan.reflection_enabled,
        planned_query_count: length(plan.search_queries || []),
        query_count: length(retrieval.traces || [])
      },
      runtime: runtime
    }
  end
end
