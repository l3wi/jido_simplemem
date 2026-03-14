defmodule Jido.SimpleMem.Actions.Remember do
  @moduledoc false

  use Jido.Action,
    name: "simplemem_remember",
    description: "Remember a SimpleMem unit",
    schema: [
      id: [type: :string, required: false],
      namespace: [type: :string, required: false],
      class: [type: :any, required: false],
      kind: [type: :any, required: false],
      text: [type: :string, required: false],
      content: [type: :any, required: false],
      tags: [type: :any, required: false],
      source: [type: :any, required: false],
      observed_at: [type: :any, required: false],
      expires_at: [type: :any, required: false],
      metadata: [type: :any, required: false],
      persons: [type: :any, required: false],
      entities: [type: :any, required: false],
      location: [type: :any, required: false],
      topic: [type: :any, required: false],
      timestamp: [type: :any, required: false],
      store: [type: :any, required: false],
      store_opts: [type: :any, required: false],
      memory_result_key: [type: :any, required: false]
    ]

  @impl true
  def run(params, context) do
    case Jido.SimpleMem.remember(context, params, []) do
      {:ok, record} ->
        key = params[:memory_result_key] || :last_memory_id
        {:ok, %{key => record.id}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
