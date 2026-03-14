defmodule Jido.SimpleMem.Synthesizer do
  @moduledoc false

  alias Jido.SimpleMem.MemoryUnit

  @spec synthesize(MemoryUnit.t(), map()) :: {:ok, MemoryUnit.t()} | {:error, term()}
  def synthesize(%MemoryUnit{} = unit, runtime) do
    with {:ok, units} <- runtime.store_mod.list(runtime.namespace, runtime.store_opts) do
      case Enum.find(units, &similar?(&1, unit)) do
        nil ->
          {:ok, unit}

        existing ->
          MemoryUnit.new(%{
            id: existing.id,
            namespace: existing.namespace,
            restatement: choose_text(existing.restatement, unit.restatement),
            original_text: existing.original_text || unit.original_text,
            content: Map.merge(existing.content || %{}, unit.content || %{}),
            class: existing.class,
            kind: existing.kind,
            tags: Enum.uniq(existing.tags ++ unit.tags),
            source: existing.source || unit.source,
            observed_at: min(existing.observed_at, unit.observed_at),
            expires_at: existing.expires_at || unit.expires_at,
            timestamp: existing.timestamp || unit.timestamp,
            persons: Enum.uniq(existing.persons ++ unit.persons),
            entities: Enum.uniq(existing.entities ++ unit.entities),
            location: existing.location || unit.location,
            topic: existing.topic || unit.topic,
            keywords: Enum.uniq(existing.keywords ++ unit.keywords),
            metadata: Map.merge(existing.metadata || %{}, unit.metadata || %{}),
            embedding: if(existing.embedding == [], do: unit.embedding, else: existing.embedding)
          })
      end
    end
  end

  defp similar?(left, right) do
    compatible_people?(left, right) and
      (left.restatement == right.restatement or
         (overlap(left.keywords, right.keywords) >= 3 and overlap(left.persons, right.persons) > 0) or
         (left.topic != nil and left.topic == right.topic and
            overlap(left.persons, right.persons) > 0))
  end

  defp overlap(left, right),
    do: MapSet.intersection(MapSet.new(left), MapSet.new(right)) |> MapSet.size()

  defp choose_text(left, right) do
    if String.length(left) >= String.length(right), do: left, else: right
  end

  defp compatible_people?(left, right) do
    cond do
      left.persons == [] or right.persons == [] -> true
      overlap(left.persons, right.persons) > 0 -> true
      true -> false
    end
  end
end
