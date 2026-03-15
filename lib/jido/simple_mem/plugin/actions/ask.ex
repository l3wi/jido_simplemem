defmodule Jido.SimpleMem.Actions.Ask do
  @moduledoc false

  use Jido.Action,
    name: "simplemem_ask",
    description: "Answer a question from buffered SimpleMem state",
    schema: [
      question: [type: :string, required: true],
      limit: [type: :integer, required: false],
      answer_result_key: [type: :any, required: false]
    ]

  @impl true
  def run(params, context) do
    target = Map.get(context, :agent, context)

    case Jido.SimpleMem.ask(target, params, []) do
      {:ok, result} ->
        key = params[:answer_result_key] || :memory_answer

        {:ok,
         %{key => result.answer, memory_context: result.context, memory_results: result.records}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
