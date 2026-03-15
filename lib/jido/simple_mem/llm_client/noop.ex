defmodule Jido.SimpleMem.LLMClient.Noop do
  @moduledoc false

  @behaviour Jido.SimpleMem.LLMClient

  @impl true
  def extract_window(_dialogues, _previous_entries, _opts), do: {:error, :not_implemented}

  @impl true
  def synthesize(_entries, _previous_entries, _opts), do: {:error, :not_implemented}

  @impl true
  def plan(_query, _opts), do: {:error, :not_implemented}

  @impl true
  def reflect(_question, _records, _plan, _opts), do: {:error, :not_implemented}

  @impl true
  def answer(_question, _records, _opts), do: {:error, :not_implemented}
end
