defmodule Jido.SimpleMem.Examples.SimpleMemoryAgent do
  @moduledoc """
  Minimal Jido agent showing how to use `Jido.SimpleMem.Plugin`.

  The agent keeps memory result metadata in its root state while actual memory
  records live in the configured SimpleMem store.
  """

  alias Jido.SimpleMem.Actions.{Answer, Forget, Remember, Retrieve}

  use Jido.Agent,
    name: "simple_memory_agent",
    description: "Example agent that stores, queries, answers, and forgets memory",
    schema: [
      last_memory_id: [type: :string, default: nil],
      memory_results: [type: :any, default: []],
      memory_answer: [type: :string, default: nil],
      memory_context: [type: :string, default: nil],
      last_memory_deleted?: [type: :boolean, default: false]
    ],
    plugins: [
      {Jido.SimpleMem.Plugin,
       %{
         auto_capture: false,
         capture_signal_patterns: []
       }}
    ]

  @spec remember(Jido.Agent.t(), String.t(), map()) ::
          {:ok, Jido.Agent.t(), String.t() | nil}
  def remember(agent, text, attrs \\ %{}) when is_binary(text) and is_map(attrs) do
    params = Map.merge(attrs, %{text: text})
    {updated_agent, _directives} = cmd(agent, {Remember, params})
    {:ok, updated_agent, updated_agent.state.last_memory_id}
  end

  @spec query(Jido.Agent.t(), String.t(), map()) ::
          {:ok, Jido.Agent.t(), [Jido.Memory.Record.t()]}
  def query(agent, question, attrs \\ %{}) when is_binary(question) and is_map(attrs) do
    params =
      attrs
      |> Map.merge(%{question: question})
      |> Map.put(:memory_result_key, :memory_results)

    {updated_agent, _directives} = cmd(agent, {Retrieve, params})
    {:ok, updated_agent, updated_agent.state.memory_results || []}
  end

  @spec answer_from_memory(Jido.Agent.t(), String.t()) ::
          {:ok, Jido.Agent.t(), String.t() | nil}
  def answer_from_memory(agent, question) when is_binary(question) do
    {updated_agent, _directives} = cmd(agent, {Answer, %{question: question}})
    {:ok, updated_agent, updated_agent.state.memory_answer}
  end

  @spec forget(Jido.Agent.t(), String.t()) :: {:ok, Jido.Agent.t(), boolean()}
  def forget(agent, memory_id) when is_binary(memory_id) do
    {updated_agent, _directives} = cmd(agent, {Forget, %{id: memory_id}})
    {:ok, updated_agent, updated_agent.state.last_memory_deleted?}
  end
end
