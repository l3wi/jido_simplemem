defmodule Jido.SimpleMem.Actions.PostTurn do
  @moduledoc false

  use Jido.Action,
    name: "simplemem_post_turn",
    description: "Persist memory after a turn",
    schema: [
      text: [type: :string, required: false],
      user_input: [type: :string, required: false],
      assistant_response: [type: :string, required: false],
      tags: [type: :any, required: false],
      metadata: [type: :any, required: false]
    ]

  @impl true
  def run(params, context) do
    text =
      params[:text] ||
        [params[:user_input], params[:assistant_response]]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

    attrs =
      params
      |> Map.take([:tags, :metadata])
      |> Map.put(:text, text)
      |> Map.put_new(:kind, :turn_summary)

    case Jido.SimpleMem.remember(context, attrs, []) do
      {:ok, record} -> {:ok, %{last_memory_id: record.id}}
      {:error, reason} -> {:error, reason}
    end
  end
end
