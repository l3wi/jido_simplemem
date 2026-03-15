defmodule Jido.SimpleMem.EmbeddingVector do
  @moduledoc false

  @spec expected_dimension(map()) :: nil | pos_integer()
  def expected_dimension(runtime) when is_map(runtime) do
    dimension_from(runtime[:embedding_dimensions]) ||
      dimension_from(runtime[:embedding_opts] && runtime.embedding_opts[:dimensions]) ||
      dimension_from(runtime[:store_opts] && runtime.store_opts[:vector_dimensions])
  end

  @spec align(keyword(), keyword()) ::
          {:ok, {keyword(), keyword(), nil | pos_integer()}} | {:error, term()}
  def align(store_opts, embedding_opts)
      when is_list(store_opts) and is_list(embedding_opts) do
    store_dimension = dimension_from(store_opts[:vector_dimensions])
    embedding_dimension = dimension_from(embedding_opts[:dimensions])

    case {store_dimension, embedding_dimension} do
      {nil, nil} ->
        {:ok, {store_opts, embedding_opts, nil}}

      {dimension, nil} ->
        {:ok,
         {Keyword.put(store_opts, :vector_dimensions, dimension),
          Keyword.put(embedding_opts, :dimensions, dimension), dimension}}

      {nil, dimension} ->
        {:ok,
         {Keyword.put(store_opts, :vector_dimensions, dimension),
          Keyword.put(embedding_opts, :dimensions, dimension), dimension}}

      {left, right} when left == right ->
        {:ok,
         {Keyword.put(store_opts, :vector_dimensions, left),
          Keyword.put(embedding_opts, :dimensions, left), left}}

      {left, right} ->
        {:error, {:embedding_dimension_mismatch, %{store: left, embedding: right}}}
    end
  end

  @spec validate([number()], map(), atom()) :: :ok | {:error, term()}
  def validate(vector, runtime, stage)
      when is_list(vector) and is_map(runtime) and is_atom(stage) do
    case expected_dimension(runtime) do
      nil ->
        :ok

      expected when length(vector) == expected ->
        :ok

      expected ->
        {:error,
         {:invalid_embedding_dimensions,
          %{expected: expected, actual: length(vector), stage: stage}}}
    end
  end

  defp dimension_from(value) when is_integer(value) and value > 0, do: value
  defp dimension_from(_), do: nil
end
