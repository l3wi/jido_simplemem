defmodule Jido.SimpleMem.Examples.SimpleMemoryAgent do
  @moduledoc """
  Minimal Jido agent showing the passive SimpleMem chat workflow.

  The agent retrieves memory before replying, appends dialogue after replying,
  and relies on `finalize` to flush incomplete trailing windows.
  """

  alias Jido.SimpleMem.Actions.{Ask, Finalize, PostTurn, PreTurn}

  use Jido.Agent,
    name: "simple_memory_agent",
    description: "Example agent that chats with passive pre/post turn memory hooks",
    schema: [
      last_user_input: [type: :string, default: nil],
      last_response: [type: :string, default: nil],
      memory_answer: [type: :string, default: nil],
      memory_context: [type: :string, default: nil],
      buffer_remaining: [type: :integer, default: 0]
    ],
    plugins: [
      {Jido.SimpleMem.Plugin,
       %{
         window_size: 4,
         overlap_size: 1
       }}
    ]

  @spec chat(Jido.Agent.t(), String.t()) :: {:ok, Jido.Agent.t(), String.t()}
  def chat(agent, user_input) when is_binary(user_input) do
    {pre_turn_agent, _directives} =
      cmd(
        agent,
        {PreTurn,
         %{
           user_input: user_input,
           context_result_key: :memory_context
         }}
      )

    {asked_agent, _directives} =
      cmd(pre_turn_agent, {Ask, %{question: user_input, answer_result_key: :memory_answer}})

    response =
      build_response(
        user_input,
        asked_agent.state.memory_answer,
        asked_agent.state.memory_context
      )

    {updated_agent, _directives} =
      cmd(
        asked_agent,
        {PostTurn,
         %{
           user_input: user_input,
           assistant_response: response
         }}
      )

    updated_agent = put_in(updated_agent.state.last_user_input, user_input)
    updated_agent = put_in(updated_agent.state.last_response, response)

    {:ok, updated_agent, response}
  end

  @spec finalize_memory(Jido.Agent.t()) :: {:ok, Jido.Agent.t(), non_neg_integer()}
  def finalize_memory(agent) do
    {updated_agent, _directives} = cmd(agent, {Finalize, %{}})
    {:ok, updated_agent, updated_agent.state.memory_count || 0}
  end

  defp build_response(_user_input, memory_answer, memory_context) do
    cond do
      useful_memory_answer?(memory_answer) ->
        memory_answer

      present_text?(memory_context) ->
        "I found some related memory context, but not a precise answer yet."

      true ->
        "I don't have that in memory yet, but I can learn it from future turns."
    end
  end

  defp useful_memory_answer?(answer) do
    present_text?(answer) and answer != "No relevant information found"
  end

  defp present_text?(value), do: is_binary(value) and String.trim(value) != ""
end
