defmodule Jido.SimpleMem.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Jido.SimpleMem.WorkerRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Jido.SimpleMem.WorkerSupervisor},
      {Task.Supervisor, name: Jido.SimpleMem.TaskSupervisor},
      Jido.SimpleMem.JobRunner
    ]

    opts = [strategy: :one_for_one, name: Jido.SimpleMem.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
