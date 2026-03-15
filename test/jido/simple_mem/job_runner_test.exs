defmodule Jido.SimpleMem.JobRunnerTest do
  use ExUnit.Case, async: false

  alias Jido.SimpleMem.JobRunner

  setup do
    previous_limit = Application.get_env(:jido_simplemem, :job_runner_completed_job_limit)
    Application.put_env(:jido_simplemem, :job_runner_completed_job_limit, 1)

    on_exit(fn ->
      if is_nil(previous_limit) do
        Application.delete_env(:jido_simplemem, :job_runner_completed_job_limit)
      else
        Application.put_env(:jido_simplemem, :job_runner_completed_job_limit, previous_limit)
      end
    end)
  end

  test "completed jobs are retained only up to the configured limit" do
    assert {:ok, first_job} = JobRunner.enqueue(:first, fn -> :first_result end)
    assert {:ok, :first_result} = JobRunner.await(first_job.id)
    assert {:ok, %{status: :completed}} = JobRunner.status(first_job.id)

    assert {:ok, second_job} = JobRunner.enqueue(:second, fn -> :second_result end)
    assert {:ok, :second_result} = JobRunner.await(second_job.id)

    assert :not_found = JobRunner.status(first_job.id)

    assert {:ok, %{status: :completed, result: {:ok, :second_result}}} =
             JobRunner.status(second_job.id)
  end
end
