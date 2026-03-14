defmodule Jido.SimpleMem.LLMClient.Noop do
  @moduledoc false

  @behaviour Jido.SimpleMem.LLMClient

  @impl true
  def extract(_attrs, _opts), do: {:error, :not_implemented}

  @impl true
  def plan(_query, _opts), do: {:error, :not_implemented}

  @impl true
  def answer(_question, _records, _opts), do: {:error, :not_implemented}
end
