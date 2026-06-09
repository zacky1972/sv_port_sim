defmodule SvPortSim.Verilator.DockerWorker do
  @moduledoc """
  Owns a long-running Verilator Docker container for repeated `docker exec` jobs.

  The worker is intentionally small: it starts or reuses one container with the
  host workspace mounted at `/work`, then serializes Verilator invocations
  through `GenServer.call/3`. Callers can pass the worker to
  `SvPortSim.Verilator.Docker.compile/4` with `docker_mode: :persistent` and
  `docker_worker: worker`.
  """

  use GenServer

  alias DockerAvailability, as: DockerProbe

  @container_work_dir "/work"
  @default_image "verilator/verilator:latest"
  @default_worker_name "sv_port_sim_verilator"

  @type run_result :: %{
          required(:status) => non_neg_integer(),
          required(:log) => String.t(),
          required(:command) => [String.t()],
          required(:docker) => Path.t(),
          required(:workspace_dir) => Path.t(),
          required(:container_name) => String.t(),
          required(:container_id) => String.t()
        }

  @doc """
  Starts a Docker worker.

  Useful options are `:docker`, `:image`, `:workspace_dir`, `:container_name`,
  `:docker_worker_name`, `:user`, `:reuse`, and `:cleanup`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name_opt =
      case Keyword.get(opts, :name) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, name_opt)
  end

  @doc """
  Starts or reuses a globally registered worker for `:docker_worker_name`.
  """
  @spec start_or_reuse(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_or_reuse(opts \\ []) do
    worker_name =
      Keyword.get(
        opts,
        :docker_worker_name,
        Keyword.get(opts, :container_name, @default_worker_name)
      )

    global_name = global_name(worker_name)

    case :global.whereis_name(global_name) do
      :undefined ->
        opts
        |> Keyword.put(:name, {:global, global_name})
        |> start_link()

      pid when is_pid(pid) ->
        {:ok, pid}
    end
  end

  @doc """
  Runs Verilator inside the persistent container.
  """
  @spec run(GenServer.server(), [String.t()], keyword()) :: {:ok, run_result()} | {:error, term()}
  def run(worker, verilator_args, opts \\ []) when is_list(verilator_args) do
    GenServer.call(worker, {:run, verilator_args}, Keyword.get(opts, :timeout, :infinity))
  end

  @doc "Returns worker metadata."
  @spec info(GenServer.server()) :: {:ok, map()}
  def info(worker) do
    GenServer.call(worker, :info)
  end

  @doc "Stops the worker process."
  @spec stop(GenServer.server()) :: :ok
  def stop(worker) do
    maybe_unlink(worker)

    case stop_worker(worker) do
      :ok -> :ok
      {:exit, reason} -> handle_stop_exit(reason)
    end
  end

  defp stop_worker(worker) do
    GenServer.call(worker, :stop, :infinity)
  catch
    :exit, reason -> {:exit, reason}
  end

  defp maybe_unlink(pid) when is_pid(pid) do
    Process.unlink(pid)
    :ok
  end

  defp maybe_unlink(_worker), do: :ok

  defp handle_stop_exit({:noproc, _details}), do: :ok
  defp handle_stop_exit(:noproc), do: :ok
  defp handle_stop_exit(:normal), do: :ok
  defp handle_stop_exit(:shutdown), do: :ok
  defp handle_stop_exit({:shutdown, _details}), do: :ok
  defp handle_stop_exit(reason), do: exit(reason)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, docker} <- docker_executable(opts),
         {:ok, image} <- image(opts),
         {:ok, workspace_dir} <- workspace_dir(opts),
         {:ok, container_name} <- container_name(opts),
         :ok <- mkdir_p(workspace_dir) do
      state = %{
        docker: docker,
        image: image,
        workspace_dir: workspace_dir,
        container_name: container_name,
        container_id: nil,
        user: Keyword.get(opts, :user, :current),
        reuse?: Keyword.get(opts, :reuse, true),
        cleanup: Keyword.get(opts, :cleanup, :manual)
      }

      case ensure_container(state) do
        {:ok, container_id} -> {:ok, %{state | container_id: container_id}}
        {:error, reason} -> {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply,
     {:ok,
      %{
        docker: state.docker,
        image: state.image,
        workspace_dir: state.workspace_dir,
        container_name: state.container_name,
        container_id: state.container_id
      }}, state}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    :ok = maybe_cleanup_container(state)
    {:stop, :normal, :ok, %{state | cleanup: :manual}}
  end

  @impl true
  def handle_call({:run, verilator_args}, _from, state) do
    exec_args =
      [
        "exec",
        "--workdir",
        @container_work_dir
      ] ++
        docker_user_args(state.user) ++
        [
          state.container_name,
          "verilator"
        ] ++ verilator_args

    try do
      {log, status} = System.cmd(state.docker, exec_args, stderr_to_stdout: true)

      {:reply,
       {:ok,
        %{
          status: status,
          log: log,
          command: [state.docker | exec_args],
          docker: state.docker,
          workspace_dir: state.workspace_dir,
          container_name: state.container_name,
          container_id: state.container_id
        }}, state}
    rescue
      e in ErlangError ->
        {:reply, {:error, {:docker_exec_failed, Exception.message(e)}}, state}
    end
  end

  @impl true
  def handle_info({:EXIT, port, :normal}, state) when is_port(port) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, pid, :normal}, state) when is_pid(pid) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, pid, :shutdown}, state) when is_pid(pid) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    maybe_cleanup_container(state)
  end

  defp maybe_cleanup_container(%{cleanup: :on_exit} = state), do: cleanup_container(state)
  defp maybe_cleanup_container(_state), do: :ok

  defp cleanup_container(state) do
    _ = System.cmd(state.docker, ["rm", "-f", state.container_name], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp ensure_container(%{reuse?: true} = state) do
    case inspect_running(state) do
      {:ok, container_id} -> {:ok, container_id}
      :not_running -> start_container(state)
    end
  end

  defp ensure_container(state) do
    _ = System.cmd(state.docker, ["rm", "-f", state.container_name], stderr_to_stdout: true)
    start_container(state)
  end

  defp inspect_running(state) do
    case System.cmd(
           state.docker,
           ["inspect", "-f", "{{.State.Running}}", state.container_name],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        if String.trim(output) == "true" do
          {:ok, state.container_name}
        else
          :not_running
        end

      {_output, _status} ->
        :not_running
    end
  rescue
    _ -> :not_running
  end

  defp start_container(state) do
    args =
      [
        "run",
        "-d",
        "--name",
        state.container_name
      ] ++
        docker_user_args(state.user) ++
        [
          "--mount",
          "type=bind,source=#{state.workspace_dir},target=#{@container_work_dir}",
          "--workdir",
          @container_work_dir,
          "--entrypoint",
          "sh",
          state.image,
          "-c",
          "while true; do sleep 3600; done"
        ]

    case System.cmd(state.docker, args, stderr_to_stdout: true) do
      {container_id, 0} ->
        {:ok, String.trim(container_id)}

      {_output, _status} ->
        retry_start_container_after_rm(state, args)
    end
  rescue
    e in ErlangError ->
      {:error, {:docker_worker_start_failed, 127, Exception.message(e)}}
  end

  defp retry_start_container_after_rm(state, args) do
    _ = System.cmd(state.docker, ["rm", "-f", state.container_name], stderr_to_stdout: true)

    case System.cmd(state.docker, args, stderr_to_stdout: true) do
      {container_id, 0} ->
        {:ok, String.trim(container_id)}

      {output, status} ->
        {:error,
         {:docker_worker_start_failed, status, String.trim(output), [state.docker | args]}}
    end
  rescue
    e in ErlangError ->
      {:error, {:docker_worker_start_failed, 127, Exception.message(e)}}
  end

  defp docker_executable(opts) do
    case Keyword.get(opts, :docker) do
      nil ->
        DockerProbe.executable()

      docker when is_binary(docker) ->
        {:ok, docker}

      docker ->
        {:error, {:invalid_docker_executable, docker}}
    end
  end

  defp image(opts) do
    case Keyword.get(opts, :image, @default_image) do
      image when is_binary(image) and byte_size(image) > 0 -> {:ok, image}
      image -> {:error, {:invalid_image, image}}
    end
  end

  defp workspace_dir(opts) do
    dir = Keyword.get(opts, :workspace_dir, Path.join(["_build", "sv_port_sim", "docker_worker"]))

    if is_binary(dir) and byte_size(dir) > 0 do
      {:ok, Path.expand(dir)}
    else
      {:error, {:invalid_docker_worker_workspace, dir}}
    end
  end

  defp container_name(opts) do
    name =
      Keyword.get(
        opts,
        :container_name,
        Keyword.get(opts, :docker_worker_name, @default_worker_name)
      )

    if is_binary(name) and byte_size(name) > 0 do
      {:ok, name}
    else
      {:error, {:invalid_docker_worker_name, name}}
    end
  end

  defp mkdir_p(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, path, reason}}
    end
  end

  defp docker_user_args(:current) do
    case current_user() do
      {:ok, user} -> ["--user", user]
      :error -> []
    end
  end

  defp docker_user_args(nil), do: []
  defp docker_user_args(false), do: []
  defp docker_user_args(user) when is_binary(user) and byte_size(user) > 0, do: ["--user", user]
  defp docker_user_args(_user), do: []

  defp current_user() do
    with {uid, 0} <- System.cmd("id", ["-u"], stderr_to_stdout: true),
         {gid, 0} <- System.cmd("id", ["-g"], stderr_to_stdout: true) do
      {:ok, "#{String.trim(uid)}:#{String.trim(gid)}"}
    else
      _ -> :error
    end
  rescue
    _ in ErlangError -> :error
  end

  defp global_name(worker_name), do: {__MODULE__, to_string(worker_name)}
end
