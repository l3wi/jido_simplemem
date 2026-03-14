defmodule Jido.SimpleMem.Retriever do
  @moduledoc false

  @spec retrieve(map(), map()) :: {:ok, [map()]} | {:error, term()}
  def retrieve(plan, runtime) do
    runtime.store_mod.search(runtime.namespace, plan, runtime.store_opts)
  end
end
