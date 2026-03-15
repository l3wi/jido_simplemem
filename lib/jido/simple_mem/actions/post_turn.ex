defmodule Jido.SimpleMem.Actions.PostTurn do
  @moduledoc false

  use Jido.Action,
    name: "simplemem_post_turn",
    description: "Append a turn to the buffered SimpleMem session",
    schema: [
      text: [type: :string, required: false],
      user_input: [type: :string, required: false],
      assistant_response: [type: :string, required: false],
      tool_results: [type: :any, required: false],
      tags: [type: :any, required: false],
      metadata: [type: :any, required: false],
      session_id: [type: :string, required: false],
      await: [type: :boolean, required: false],
      timeout_ms: [type: :integer, required: false]
    ]

  @impl true
  def run(params, context) do
    target = Map.get(context, :agent, context)

    dialogues =
      []
      |> maybe_add_dialogue("user", params[:user_input], params)
      |> maybe_add_dialogue("assistant", params[:assistant_response] || params[:text], params)

    with {:ok, job} <-
           Jido.SimpleMem.enqueue_add_dialogues(target, dialogues, session_opts(params)) do
      if params[:await] do
        await_result(job.id, params[:timeout_ms])
      else
        {:ok,
         %{
           job_id: job.id,
           status: job.status,
           queued?: true,
           dialogue_count: length(dialogues)
         }}
      end
    end
  end

  defp maybe_add_dialogue(dialogues, _speaker, value, _params) when value in [nil, ""],
    do: dialogues

  defp maybe_add_dialogue(dialogues, speaker, value, params) do
    metadata =
      params[:metadata]
      |> normalize_metadata()
      |> Map.put("speaker", speaker)

    dialogues ++ [%{speaker: speaker, content: value, metadata: metadata}]
  end

  defp session_opts(params) do
    []
    |> maybe_put(:session_id, params[:session_id])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp await_result(job_id, timeout_ms) do
    case Jido.SimpleMem.await_job(job_id, timeout_ms || 30_000) do
      {:ok, {:ok, result}} ->
        {:ok,
         %{
           job_id: job_id,
           status: :completed,
           last_memory_id: result[:last_memory_id],
           memory_ids: result[:memory_ids],
           memory_count: result[:memory_count],
           buffer_remaining: result[:buffer_remaining],
           finalized?: result[:finalized?],
           auto_finalized?: result[:auto_finalized?]
         }}

      {:ok, result} when is_map(result) ->
        {:ok,
         %{
           job_id: job_id,
           status: :completed,
           last_memory_id: result[:last_memory_id],
           memory_ids: result[:memory_ids],
           memory_count: result[:memory_count],
           buffer_remaining: result[:buffer_remaining],
           finalized?: result[:finalized?],
           auto_finalized?: result[:auto_finalized?]
         }}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_metadata(nil), do: %{}
  defp normalize_metadata(%{} = metadata), do: metadata
  defp normalize_metadata(list) when is_list(list), do: Map.new(list)
  defp normalize_metadata(_), do: %{}
end
