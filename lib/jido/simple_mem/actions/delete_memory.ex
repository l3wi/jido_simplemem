defmodule Jido.SimpleMem.Actions.DeleteMemory do
  @moduledoc false

  use Jido.Action,
    name: "simplemem_delete_memory",
    description: "Delete a stored SimpleMem memory by id",
    schema: [
      id: [type: :string, required: true],
      memory_result_key: [type: :any, required: false]
    ]

  @impl true
  def run(params, context) do
    target = Map.get(context, :agent, context)

    case Jido.SimpleMem.delete_memory(target, params.id, []) do
      {:ok, deleted?} ->
        key = params[:memory_result_key] || :last_memory_deleted?
        {:ok, %{key => deleted?}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
