defmodule Jido.SimpleMem.Store.Lance.PortClient do
  @moduledoc false

  use GenServer

  @behaviour Jido.SimpleMem.Store.Lance.Client

  @timeout 60_000

  defstruct [:path, :port, :buffer, :next_id, :pending]

  @impl true
  def ensure_ready(opts) do
    request(opts, %{"op" => "ensure_ready", "options" => worker_options(opts)})
    |> map_ok(fn _ -> :ok end)
  end

  @impl true
  def put(unit, opts) when is_map(unit) do
    request(opts, %{"op" => "put", "unit" => unit, "options" => worker_options(opts)})
  end

  @impl true
  def get(namespace, id, opts) do
    request(opts, %{
      "op" => "get",
      "namespace" => namespace,
      "entry_id" => id,
      "options" => worker_options(opts)
    })
    |> map_not_found()
  end

  @impl true
  def delete(namespace, id, opts) do
    request(opts, %{
      "op" => "delete",
      "namespace" => namespace,
      "entry_id" => id,
      "options" => worker_options(opts)
    })
    |> map_ok(fn _ -> :ok end)
  end

  @impl true
  def list(namespace, opts) do
    request(opts, %{"op" => "list", "namespace" => namespace, "options" => worker_options(opts)})
  end

  @impl true
  def search(namespace, plan, opts) do
    request(opts, %{
      "op" => "search",
      "namespace" => namespace,
      "plan" => plan,
      "options" => worker_options(opts)
    })
  end

  @impl true
  def load_buffer(namespace, session_id, opts) do
    request(opts, %{
      "op" => "load_buffer",
      "namespace" => namespace,
      "session_id" => session_id,
      "options" => worker_options(opts)
    })
  end

  @impl true
  def replace_buffer(namespace, session_id, state, opts) do
    request(opts, %{
      "op" => "replace_buffer",
      "namespace" => namespace,
      "session_id" => session_id,
      "state" => state,
      "options" => worker_options(opts)
    })
    |> map_ok(fn _ -> :ok end)
  end

  @impl true
  def delete_buffer(namespace, session_id, opts) do
    request(opts, %{
      "op" => "delete_buffer",
      "namespace" => namespace,
      "session_id" => session_id,
      "options" => worker_options(opts)
    })
    |> map_ok(fn _ -> :ok end)
  end

  defp request(opts, payload) do
    with {:ok, pid} <- ensure_started(opts) do
      GenServer.call(pid, {:request, payload}, timeout(opts))
    end
  end

  defp ensure_started(opts) do
    path = path(opts)

    case Registry.lookup(Jido.SimpleMem.WorkerRegistry, path) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        spec = {__MODULE__, opts}

        case DynamicSupervisor.start_child(Jido.SimpleMem.WorkerSupervisor, spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, {:already_present, _}} -> ensure_started(opts)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, path(opts)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(path(opts)))
  end

  @impl true
  def init(opts) do
    path = path(opts)
    File.mkdir_p!(path)

    port =
      Port.open({:spawn_executable, executable(opts)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 65_536},
        args: command_args(opts),
        cd: File.cwd!()
      ])

    {:ok, %__MODULE__{path: path, port: port, buffer: "", next_id: 1, pending: %{}}}
  end

  @impl true
  def handle_call({:request, payload}, from, state) do
    id = state.next_id
    message = payload |> Map.put("id", id) |> Jason.encode!() |> Kernel.<>("\n")
    true = Port.command(state.port, message)

    {:noreply,
     %{
       state
       | next_id: id + 1,
         pending: Map.put(state.pending, id, from)
     }}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case Jason.decode(line) do
      {:ok, %{"id" => id, "status" => "ok", "result" => result}} ->
        {from, pending} = Map.pop(state.pending, id)
        if from, do: GenServer.reply(from, {:ok, result})
        {:noreply, %{state | pending: pending}}

      {:ok, %{"id" => id, "status" => "error", "error" => error}} ->
        {from, pending} = Map.pop(state.pending, id)
        if from, do: GenServer.reply(from, {:error, error})
        {:noreply, %{state | pending: pending}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({port, {:data, {:noeol, _line}}}, %{port: port} = state), do: {:noreply, state}

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Enum.each(state.pending, fn {_id, from} ->
      GenServer.reply(from, {:error, {:worker_exit, status}})
    end)

    {:stop, {:worker_exit, status}, %{state | pending: %{}}}
  end

  defp worker_options(opts) do
    %{
      "path" => path(opts),
      "memory_table" => Keyword.get(opts, :memory_table, "memory_entries"),
      "buffer_table" => Keyword.get(opts, :buffer_table, "session_buffers"),
      "vector_dimensions" => Keyword.get(opts, :vector_dimensions)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp executable(opts) do
    cond do
      uv = Keyword.get(opts, :uv_executable) ->
        uv

      uv = System.find_executable("uv") ->
        uv

      py = Keyword.get(opts, :python_executable) ->
        py

      py = System.find_executable("python3") ->
        py

      true ->
        raise ArgumentError, "uv or python3 executable is required for the LanceDB worker"
    end
  end

  defp command_args(opts) do
    script = worker_script()

    cond do
      Keyword.get(opts, :uv_executable) || System.find_executable("uv") ->
        ["run", script]

      true ->
        [script]
    end
  end

  defp worker_script do
    :jido_simplemem
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("python/lance_worker.py")
  end

  defp timeout(opts), do: Keyword.get(opts, :worker_start_timeout_ms, @timeout)

  defp path(opts) do
    opts
    |> Keyword.get(:path)
    |> case do
      value when is_binary(value) and value != "" -> Path.expand(value)
      _ -> raise ArgumentError, "Lance path required"
    end
  end

  defp via(path), do: {:via, Registry, {Jido.SimpleMem.WorkerRegistry, path}}

  defp map_ok({:ok, value}, fun), do: {:ok, fun.(value)}
  defp map_ok({:error, _reason} = error, _fun), do: error

  defp map_not_found({:ok, nil}), do: :not_found
  defp map_not_found({:ok, %{"status" => "not_found"}}), do: :not_found
  defp map_not_found(other), do: other
end
