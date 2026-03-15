defmodule Jido.SimpleMem.Actions.GetAllMemories do
  @moduledoc false

  use Jido.Action,
    name: "simplemem_get_all_memories",
    description: "List all stored SimpleMem memories for the current namespace",
    schema: [
      memory_result_key: [type: :any, required: false]
    ]

  @impl true
  def run(params, context) do
    target = Map.get(context, :agent, context)

    case Jido.SimpleMem.get_all_memories(target, []) do
      {:ok, records} ->
        key = params[:memory_result_key] || :memory_results
        {:ok, %{key => records}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
