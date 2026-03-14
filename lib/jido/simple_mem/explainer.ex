defmodule Jido.SimpleMem.Explainer do
  @moduledoc false

  @spec explain(map()) :: map()
  def explain(%{query: query, plan: plan, runtime: runtime, ranked: ranked, records: records}) do
    %{
      query: query,
      plan: Map.drop(plan, [:query_embedding]),
      records: records,
      scored_candidates:
        Enum.map(ranked.candidates, fn candidate ->
          %{
            id: candidate.unit.id,
            restatement: candidate.unit.restatement,
            semantic_score: candidate.semantic_score,
            lexical_score: candidate.lexical_score,
            symbolic_score: candidate.symbolic_score,
            recency_score: candidate.recency_score,
            total_score: candidate.total_score
          }
        end),
      selected_ids: Enum.map(ranked.selected, & &1.unit.id),
      context_pack: Jido.SimpleMem.build_context(records, runtime.context_token_budget),
      decision_trace: %{
        question_type: plan.question_type,
        limit: plan.limit,
        reflection_enabled: plan.reflection_enabled
      },
      runtime: runtime
    }
  end
end
