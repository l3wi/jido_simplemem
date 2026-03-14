defmodule Jido.SimpleMem.Actions.Forget do
  @moduledoc false

  use Jido.Action,
    name: "simplemem_forget",
    description: "Delete a SimpleMem record",
    schema: [
      id: [type: :string, required: true],
      memory_result_key: [type: :any, required: false]
    ]

  @impl true
  def run(params, context) do
    case Jido.SimpleMem.forget(context, params.id, []) do
      {:ok, deleted?} ->
        key = params[:memory_result_key] || :last_memory_deleted?
        {:ok, %{key => deleted?}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
