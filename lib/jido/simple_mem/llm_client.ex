defmodule Jido.SimpleMem.LLMClient do
  @moduledoc false

  @callback extract_window(
              [Jido.SimpleMem.Dialogue.t()],
              [Jido.SimpleMem.MemoryUnit.t()],
              keyword()
            ) ::
              {:ok, [map()]} | {:error, term()}
  @callback synthesize([map()], [Jido.SimpleMem.MemoryUnit.t()], keyword()) ::
              {:ok, [map()]} | {:error, term()}
  @callback plan(map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback reflect(map(), [Jido.Memory.Record.t()], map(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback answer(map(), [Jido.Memory.Record.t()], keyword()) :: {:ok, map()} | {:error, term()}
end
