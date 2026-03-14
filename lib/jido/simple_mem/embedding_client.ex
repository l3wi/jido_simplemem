defmodule Jido.SimpleMem.EmbeddingClient do
  @moduledoc false

  @callback embed(String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
end
