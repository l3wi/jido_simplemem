defmodule Jido.SimpleMem.Store.InMemory do
  @moduledoc false

  @behaviour Jido.SimpleMem.Store

  alias Jido.SimpleMem.{MemoryUnit, Tokenizer}

  @impl true
  def ensure_ready(opts) do
    table = Keyword.get(opts, :table, :jido_simplemem)

    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [:named_table, :public, :set])
        :ok

      _ ->
        :ok
    end
  end

  @impl true
  def put(%MemoryUnit{} = unit, opts) do
    table = Keyword.get(opts, :table, :jido_simplemem)
    true = :ets.insert(table, {{unit.namespace, unit.id}, unit})
    {:ok, unit}
  end

  @impl true
  def get(key, opts) do
    table = Keyword.get(opts, :table, :jido_simplemem)

    case :ets.lookup(table, key) do
      [{^key, unit}] -> {:ok, unit}
      [] -> :not_found
    end
  end

  @impl true
  def delete(key, opts) do
    table = Keyword.get(opts, :table, :jido_simplemem)
    true = :ets.delete(table, key)
    :ok
  end

  @impl true
  def list(namespace, opts) do
    table = Keyword.get(opts, :table, :jido_simplemem)

    units =
      table
      |> :ets.tab2list()
      |> Enum.map(&elem(&1, 1))
      |> Enum.filter(&(&1.namespace == namespace))

    {:ok, units}
  end

  @impl true
  def search(namespace, plan, opts) do
    {:ok, units} = list(namespace, opts)
    {:ok, Enum.map(filter_units(units, plan), &score_candidate(&1, plan))}
  end

  defp filter_units(units, plan) do
    Enum.filter(units, fn unit ->
      class_match?(unit, plan) and
        kind_match?(unit, plan) and
        tags_match?(unit, plan) and
        time_match?(unit, plan)
    end)
  end

  defp class_match?(_unit, %{classes: []}), do: true
  defp class_match?(unit, %{classes: classes}), do: unit.class in classes

  defp kind_match?(_unit, %{kinds: []}), do: true
  defp kind_match?(unit, %{kinds: kinds}), do: unit.kind in kinds

  defp tags_match?(unit, %{tags_all: tags_all, tags_any: tags_any}) do
    has_all = Enum.all?(tags_all, &(&1 in unit.tags))
    has_any = tags_any == [] or Enum.any?(tags_any, &(&1 in unit.tags))
    has_all and has_any
  end

  defp time_match?(unit, %{since: since, until: until}) do
    after_since = is_nil(since) or unit.observed_at >= since
    before_until = is_nil(until) or unit.observed_at <= until
    after_since and before_until
  end

  defp score_candidate(%MemoryUnit{} = unit, plan) do
    query_keywords = plan.keywords || []
    unit_keywords = unit.keywords ++ Tokenizer.tokens(unit.restatement)
    lexical_overlap = Tokenizer.overlap(query_keywords, unit_keywords)
    lexical_total = max(length(Enum.uniq(query_keywords)), 1)
    lexical_score = lexical_overlap / lexical_total

    semantic_score = Tokenizer.cosine(plan.query_embedding || [], unit.embedding || [])

    symbolic_hits =
      [
        Enum.any?(plan.persons || [], &(&1 in unit.persons)),
        Enum.any?(plan.entities || [], &(&1 in unit.entities)),
        not is_nil(plan.location) and unit.location == plan.location,
        not is_nil(plan.timestamp_hint) and unit.timestamp == plan.timestamp_hint
      ]
      |> Enum.count(& &1)

    symbolic_score =
      cond do
        symbolic_hits == 0 -> 0.0
        true -> symbolic_hits / 4.0
      end

    recency_score =
      if is_integer(unit.observed_at) do
        age_ms = max(plan.now - unit.observed_at, 1)
        1.0 / (1.0 + age_ms / 86_400_000)
      else
        0.0
      end

    %{
      unit: unit,
      lexical_score: lexical_score,
      semantic_score: semantic_score,
      symbolic_score: symbolic_score,
      recency_score: recency_score
    }
  end
end
