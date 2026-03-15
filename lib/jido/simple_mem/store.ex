defmodule Jido.SimpleMem.Store do
  @moduledoc false

  alias Jido.SimpleMem.MemoryUnit

  @type opts :: keyword()
  @type key :: {String.t(), String.t()}
  @type candidate :: %{
          unit: MemoryUnit.t(),
          lexical_score: float(),
          semantic_score: float(),
          symbolic_score: float(),
          recency_score: float(),
          channels: [atom()],
          lexical_rank: nil | non_neg_integer(),
          semantic_rank: nil | non_neg_integer(),
          structured_rank: nil | non_neg_integer()
        }

  @callback ensure_ready(opts()) :: :ok | {:error, term()}
  @callback put(MemoryUnit.t(), opts()) :: {:ok, MemoryUnit.t()} | {:error, term()}
  @callback get(key(), opts()) :: {:ok, MemoryUnit.t()} | :not_found | {:error, term()}
  @callback delete(key(), opts()) :: :ok | {:error, term()}
  @callback list(String.t(), opts()) :: {:ok, [MemoryUnit.t()]} | {:error, term()}
  @callback search(String.t(), map(), opts()) :: {:ok, [candidate()]} | {:error, term()}
  @callback load_buffer(String.t(), String.t(), opts()) :: {:ok, map()} | {:error, term()}
  @callback replace_buffer(String.t(), String.t(), map(), opts()) :: :ok | {:error, term()}
  @callback delete_buffer(String.t(), String.t(), opts()) :: :ok | {:error, term()}
end
