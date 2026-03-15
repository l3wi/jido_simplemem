defmodule Jido.SimpleMem.Actions.PreTurn do
  @moduledoc false

  use Jido.Action,
    name: "simplemem_pre_turn",
    description: "Retrieve context before a turn",
    schema: [
      question: [type: :string, required: false],
      prompt: [type: :string, required: false],
      user_input: [type: :string, required: false],
      limit: [type: :integer, required: false],
      context_result_key: [type: :any, required: false]
    ]

  @impl true
  def run(params, context) do
    target = Map.get(context, :agent, context)
    question = params[:question] || params[:prompt] || params[:user_input] || "recent context"

    with {:ok, answer} <-
           Jido.SimpleMem.ask(target, %{question: question, limit: params[:limit]}, []),
         context_key <- params[:context_result_key] || :simplemem_context do
      {:ok,
       %{
         context_key => answer.context,
         memory_results: answer.records,
         memory_answer: answer.answer
       }}
    end
  end
end
