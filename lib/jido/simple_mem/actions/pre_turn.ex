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
    question = params[:question] || params[:prompt] || params[:user_input] || "recent context"

    with {:ok, explain} <-
           Jido.SimpleMem.explain(context, %{question: question, limit: params[:limit]}, []),
         context_key <- params[:context_result_key] || :simplemem_context do
      {:ok,
       %{
         context_key => explain.context_pack,
         memory_results: explain.records,
         memory_plan: explain.plan
       }}
    end
  end
end
