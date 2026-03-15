defmodule Jido.SimpleMem.Synthesizer do
  @moduledoc false

  alias Jido.SimpleMem.MemoryUnit

  @spec synthesize_batch([MemoryUnit.t()], map()) :: {:ok, [MemoryUnit.t()]} | {:error, term()}
  def synthesize_batch(units, runtime) when is_list(units) do
    Enum.reduce_while(units, {:ok, []}, fn unit, {:ok, acc} ->
      case runtime.store_mod.put(unit, runtime.store_opts) do
        {:ok, stored} ->
          {:cont, {:ok, [stored | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, stored} -> {:ok, Enum.reverse(stored)}
      {:error, _reason} = error -> error
    end
  end
end
