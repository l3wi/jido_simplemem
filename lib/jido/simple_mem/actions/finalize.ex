defmodule Jido.SimpleMem.Actions.Finalize do
  @moduledoc false

  use Jido.Action,
    name: "simplemem_finalize",
    description: "Flush buffered SimpleMem dialogue into durable memories",
    schema: [
      session_id: [type: :string, required: false],
      await: [type: :boolean, required: false],
      timeout_ms: [type: :integer, required: false]
    ]

  @impl true
  def run(params, context) do
    target = Map.get(context, :agent, context)

    with {:ok, job} <- Jido.SimpleMem.enqueue_finalize(target, session_opts(params)) do
      if params[:await] do
        await_result(job.id, params[:timeout_ms])
      else
        {:ok,
         %{
           job_id: job.id,
           status: job.status,
           queued?: true
         }}
      end
    end
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
           buffer_remaining: result[:buffer_remaining]
         }}

      {:ok, result} when is_map(result) ->
        {:ok,
         %{
           job_id: job_id,
           status: :completed,
           last_memory_id: result[:last_memory_id],
           memory_ids: result[:memory_ids],
           memory_count: result[:memory_count],
           buffer_remaining: result[:buffer_remaining]
         }}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
