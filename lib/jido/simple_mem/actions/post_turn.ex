defmodule Jido.SimpleMem.Actions.PostTurn do
  @moduledoc false

  alias Jido.SimpleMem.Policy

  use Jido.Action,
    name: "simplemem_post_turn",
    description: "Persist memory after a turn",
    schema: [
      text: [type: :string, required: false],
      user_input: [type: :string, required: false],
      assistant_response: [type: :string, required: false],
      tool_results: [type: :any, required: false],
      tags: [type: :any, required: false],
      metadata: [type: :any, required: false]
    ]

  @impl true
  def run(params, context) do
    state =
      context
      |> Map.get(:state, %{})
      |> Map.get(Jido.SimpleMem.plugin_state_key(), %{})

    case Policy.turn_memories(params, state[:memory_policy]) do
      {:ok, memories} ->
        store_memories(memories, context)

      {:skip, reason} ->
        {:ok,
         %{
           memory_ids: [],
           memory_count: 0,
           last_memory_id: nil,
           memory_skipped?: true,
           skip_reason: reason
         }}
    end
  end

  defp store_memories(memories, context) do
    result =
      Enum.reduce_while(memories, {:ok, []}, fn attrs, {:ok, records} ->
        case Jido.SimpleMem.remember(context, attrs, []) do
          {:ok, record} -> {:cont, {:ok, [record | records]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, records} ->
        ordered_records = Enum.reverse(records)

        {:ok,
         %{
           memory_ids: Enum.map(ordered_records, & &1.id),
           memory_count: length(ordered_records),
           last_memory_id: ordered_records |> List.last() |> then(& &1.id),
           memory_skipped?: false
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
