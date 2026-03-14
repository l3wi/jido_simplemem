defmodule Jido.SimpleMem.Tokenizer do
  @moduledoc false

  @stopwords MapSet.new(~w[
    a an and are as at be by for from has have how i in is it of on or that the their this to was
    what when where who why will with you your
  ])

  @spec tokens(binary() | nil) :: [String.t()]
  def tokens(nil), do: []

  def tokens(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/u, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&MapSet.member?(@stopwords, &1))
  end

  @spec keywords(binary(), keyword()) :: [String.t()]
  def keywords(text, opts \\ []) when is_binary(text) do
    limit = Keyword.get(opts, :limit, 8)

    text
    |> tokens()
    |> Enum.frequencies()
    |> Enum.sort_by(fn {token, count} -> {-count, token} end)
    |> Enum.take(limit)
    |> Enum.map(&elem(&1, 0))
  end

  @spec overlap([String.t()], [String.t()]) :: non_neg_integer()
  def overlap(left, right) do
    left_set = MapSet.new(left)
    right_set = MapSet.new(right)
    MapSet.intersection(left_set, right_set) |> MapSet.size()
  end

  @spec cosine([number()], [number()]) :: float()
  def cosine(left, right) when length(left) == length(right) and left != [] do
    dot = Enum.zip_with(left, right, &(&1 * &2))
    left_norm = :math.sqrt(Enum.sum(Enum.map(left, &(&1 * &1))))
    right_norm = :math.sqrt(Enum.sum(Enum.map(right, &(&1 * &1))))

    if left_norm == 0.0 or right_norm == 0.0 do
      0.0
    else
      Enum.sum(dot) / (left_norm * right_norm)
    end
  end

  def cosine(_, _), do: 0.0
end
