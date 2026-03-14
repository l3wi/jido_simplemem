defmodule Jido.SimpleMem.Store.Turso.Client do
  @moduledoc false

  @type result :: %{
          optional(:rows) => [map()],
          optional(:affected_row_count) => non_neg_integer()
        }

  @callback execute(String.t(), [term()], keyword()) :: {:ok, result()} | {:error, term()}
  @callback batch([{String.t(), [term()]}], keyword()) :: {:ok, [result()]} | {:error, term()}
end
