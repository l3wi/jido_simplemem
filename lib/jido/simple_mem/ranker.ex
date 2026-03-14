defmodule Jido.SimpleMem.Ranker do
  @moduledoc false

  @spec rank([map()], map(), map()) :: {:ok, map()} | {:error, term()}
  def rank(candidates, plan, _runtime) when is_list(candidates) do
    weighted =
      Enum.map(candidates, fn candidate ->
        total =
          candidate.semantic_score * semantic_weight(plan) +
            candidate.lexical_score * lexical_weight(plan) +
            candidate.symbolic_score * symbolic_weight(plan) +
            candidate.recency_score * 0.1 +
            person_bonus(candidate, plan) -
            mismatch_penalty(candidate, plan)

        Map.put(candidate, :total_score, total)
      end)

    ordered =
      weighted
      |> Enum.sort_by(fn candidate -> {-candidate.total_score, -candidate.unit.observed_at} end)

    selected = Enum.take(ordered, plan.limit || 10)

    {:ok,
     %{
       candidates: ordered,
       selected: selected
     }}
  end

  defp semantic_weight(%{question_type: :multi_hop}), do: 0.45
  defp semantic_weight(%{question_type: :temporal}), do: 0.25
  defp semantic_weight(_), do: 0.35

  defp lexical_weight(%{question_type: :factual}), do: 0.35
  defp lexical_weight(_), do: 0.25

  defp symbolic_weight(%{question_type: :temporal}), do: 0.4
  defp symbolic_weight(%{question_type: :entity}), do: 0.4
  defp symbolic_weight(_), do: 0.3

  defp person_bonus(%{unit: unit}, %{persons: persons}) when persons != [] do
    unit_people = unit.persons || []

    cond do
      Enum.all?(persons, &(&1 in unit_people)) -> 0.75
      Enum.any?(persons, &(&1 in unit_people)) -> 0.25
      true -> 0.0
    end
  end

  defp person_bonus(_, _), do: 0.0

  defp mismatch_penalty(%{unit: unit}, %{persons: persons}) when persons != [] do
    unit_people = unit.persons || []

    cond do
      Enum.any?(persons, &(&1 in unit_people)) -> 0.0
      unit_people == [] -> 0.0
      true -> 0.35
    end
  end

  defp mismatch_penalty(_, _), do: 0.0
end
