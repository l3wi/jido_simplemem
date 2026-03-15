defmodule Jido.SimpleMem.TestSupport.FakeEmbeddingClient do
  @behaviour Jido.SimpleMem.EmbeddingClient

  alias Jido.SimpleMem.Tokenizer

  @impl true
  def embed(text, opts \\ []) when is_binary(text) do
    size = Keyword.get(opts, :dimensions) || Keyword.get(opts, :size, 32)

    vector =
      Enum.reduce(Tokenizer.tokens(text), List.duplicate(0.0, size), fn token, acc ->
        idx = :erlang.phash2(token, size)
        List.update_at(acc, idx, &(&1 + 1.0))
      end)

    {:ok, vector}
  end
end
