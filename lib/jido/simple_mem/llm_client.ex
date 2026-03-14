defmodule Jido.SimpleMem.LLMClient do
  @moduledoc false

  @callback extract(map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback plan(map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback answer(map(), [Jido.Memory.Record.t()], keyword()) :: {:ok, map()} | {:error, term()}
end
