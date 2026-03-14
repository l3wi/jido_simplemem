defmodule Jido.SimpleMem.Actions.Retrieve do
  @moduledoc false

  use Jido.Action,
    name: "simplemem_retrieve",
    description: "Retrieve SimpleMem records",
    schema: [
      question: [type: :string, required: false],
      namespace: [type: :string, required: false],
      classes: [type: :any, required: false],
      kinds: [type: :any, required: false],
      tags_any: [type: :any, required: false],
      tags_all: [type: :any, required: false],
      text_contains: [type: :any, required: false],
      since: [type: :any, required: false],
      until: [type: :any, required: false],
      limit: [type: :any, required: false],
      order: [type: :any, required: false],
      debug: [type: :boolean, required: false],
      memory_result_key: [type: :any, required: false]
    ]

  @impl true
  def run(params, context) do
    case Jido.SimpleMem.retrieve(context, params, []) do
      {:ok, records} ->
        key = params[:memory_result_key] || :memory_results
        {:ok, %{key => records}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
