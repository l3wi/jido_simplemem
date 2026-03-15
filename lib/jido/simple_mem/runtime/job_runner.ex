defmodule Jido.SimpleMem.JobRunner do
  @moduledoc false

  use GenServer

  @default_completed_job_limit 100

  @type job_result :: {:ok, term()} | {:error, term()}
  @type job_info :: %{
          id: String.t(),
          kind: atom(),
          status: :running | :completed | :failed,
          result: nil | job_result(),
          started_at: integer(),
          completed_at: nil | integer(),
          meta: map()
        }

  @spec completed_job_limit() :: pos_integer()
  def completed_job_limit do
    Application.get_env(
      :jido_simplemem,
      :job_runner_completed_job_limit,
      @default_completed_job_limit
    )
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec enqueue(atom(), (-> term()), map()) :: {:ok, job_info()}
  def enqueue(kind, fun, meta \\ %{})
      when is_atom(kind) and is_function(fun, 0) and is_map(meta) do
    GenServer.call(__MODULE__, {:enqueue, kind, fun, meta})
  end

  @spec await(String.t(), timeout()) :: job_result()
  def await(job_id, timeout \\ 30_000) when is_binary(job_id) do
    GenServer.call(__MODULE__, {:await, job_id}, timeout)
  end

  @spec status(String.t()) :: {:ok, job_info()} | :not_found
  def status(job_id) when is_binary(job_id) do
    GenServer.call(__MODULE__, {:status, job_id})
  end

  @impl true
  def init(_opts) do
    {:ok, %{jobs: %{}, refs: %{}}}
  end

  @impl true
  def handle_call({:enqueue, kind, fun, meta}, _from, state) do
    task = Task.Supervisor.async_nolink(Jido.SimpleMem.TaskSupervisor, fun)
    now = System.system_time(:millisecond)
    job_id = unique_job_id(kind)

    job = %{
      id: job_id,
      kind: kind,
      status: :running,
      result: nil,
      started_at: now,
      completed_at: nil,
      meta: meta,
      waiters: []
    }

    {:reply, {:ok, public_job(job)},
     %{
       state
       | jobs:
           Map.put(state.jobs, job_id, Map.merge(job, %{task_ref: task.ref, task_pid: task.pid})),
         refs: Map.put(state.refs, task.ref, job_id)
     }}
  end

  def handle_call({:await, job_id}, from, state) do
    case Map.get(state.jobs, job_id) do
      nil ->
        {:reply, {:error, :job_not_found}, state}

      %{status: :completed, result: {:ok, _} = result} ->
        {:reply, result, state}

      %{status: :failed, result: {:error, _} = result} ->
        {:reply, result, state}

      job ->
        updated = put_in(job[:waiters], [from | job.waiters])
        {:noreply, %{state | jobs: Map.put(state.jobs, job_id, updated)}}
    end
  end

  def handle_call({:status, job_id}, _from, state) do
    case Map.get(state.jobs, job_id) do
      nil -> {:reply, :not_found, state}
      job -> {:reply, {:ok, public_job(job)}, state}
    end
  end

  @impl true
  def handle_info({ref, result}, state) do
    case Map.pop(state.refs, ref) do
      {nil, refs} ->
        {:noreply, %{state | refs: refs}}

      {job_id, refs} ->
        Process.demonitor(ref, [:flush])
        {:noreply, complete_job(job_id, {:ok, result}, %{state | refs: refs})}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, refs} ->
        {:noreply, %{state | refs: refs}}

      {job_id, refs} ->
        job = Map.get(state.jobs, job_id)

        if job && job.status == :running do
          {:noreply, complete_job(job_id, {:error, reason}, %{state | refs: refs})}
        else
          {:noreply, %{state | refs: refs}}
        end
    end
  end

  def handle_info({:"ETS-TRANSFER", _table, _from, _heir_data}, state) do
    {:noreply, state}
  end

  defp complete_job(job_id, result, state) do
    case Map.get(state.jobs, job_id) do
      nil ->
        state

      job ->
        now = System.system_time(:millisecond)

        completed =
          job
          |> Map.put(:status, status_from_result(result))
          |> Map.put(:result, result)
          |> Map.put(:completed_at, now)

        Enum.each(job.waiters, &GenServer.reply(&1, result))

        jobs =
          state.jobs
          |> Map.put(job_id, Map.put(completed, :waiters, []))
          |> trim_completed_jobs(completed_job_limit())

        %{state | jobs: jobs}
    end
  end

  defp public_job(job) do
    job
    |> Map.take([:id, :kind, :status, :result, :started_at, :completed_at, :meta])
  end

  defp status_from_result({:ok, _}), do: :completed
  defp status_from_result({:error, _}), do: :failed

  defp trim_completed_jobs(jobs, limit) when is_integer(limit) and limit > 0 do
    completed_ids =
      jobs
      |> Enum.filter(fn {_job_id, job} -> job.status in [:completed, :failed] end)
      |> Enum.sort_by(
        fn {job_id, job} -> {job.completed_at || 0, job.started_at || 0, job_id} end,
        :desc
      )
      |> Enum.drop(limit)
      |> Enum.map(&elem(&1, 0))

    Enum.reduce(completed_ids, jobs, &Map.delete(&2, &1))
  end

  defp trim_completed_jobs(jobs, _limit), do: jobs

  defp unique_job_id(kind) do
    "smem_job_" <>
      Atom.to_string(kind) <> "_" <> Integer.to_string(System.unique_integer([:positive]))
  end
end
