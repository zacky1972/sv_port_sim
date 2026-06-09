defmodule SvPortSim.Verilator.Docker do
  @moduledoc """
  Runs Verilator inside Docker for build and lint-only flows.

  This module stages SystemVerilog source files, and in build mode a generated
  C++ wrapper, into a host-side work directory. It then mounts that directory
  into a Docker container and invokes Verilator.

  `compile_executable/4` preserves the original executable-producing API and is
  equivalent to `compile/4` with `mode: :build`. `lint/3` and `compile/4` with
  `mode: :lint_only` run Verilator with `--lint-only` and do not require or
  return a wrapper executable.
  """

  alias DockerAvailability, as: DockerProbe
  alias SvPortSim.Verilator.DockerWorker

  @app :sv_port_sim
  @default_image "verilator/verilator:latest"
  @container_work_dir "/work"
  @obj_dir_name "obj_dir"

  # Minimal support for SystemVerilog simple identifiers.
  @sv_identifier ~r/\A[A-Za-z_][A-Za-z0-9_$]*\z/

  @type compile_mode :: :build | :lint_only

  @type build_result :: %{
          required(:mode) => :build,
          required(:top_module) => String.t(),
          required(:image) => String.t(),
          required(:docker) => Path.t(),
          required(:work_dir) => Path.t(),
          required(:obj_dir) => Path.t(),
          required(:executable) => Path.t(),
          required(:command) => [String.t()],
          required(:log) => String.t()
        }

  @type lint_result :: %{
          required(:mode) => :lint_only,
          required(:top_module) => String.t(),
          required(:image) => String.t(),
          required(:docker) => Path.t(),
          required(:work_dir) => Path.t(),
          required(:obj_dir) => Path.t(),
          required(:command) => [String.t()],
          required(:log) => String.t()
        }

  @type compile_result :: build_result() | lint_result()

  @doc """
  Compiles a Verilated executable by running Verilator inside Docker.

  This function keeps the historical public API stable. It always runs build
  mode, stages `wrapper_cpp`, and verifies `obj_dir/V<top_module>` by default.
  """
  @spec compile_executable(term(), term(), term(), keyword()) ::
          {:ok, build_result()} | {:error, term()}
  def compile_executable(top_module, source_files, wrapper_cpp, opts \\ [])

  def compile_executable(top_module, source_files, wrapper_cpp, opts)
      when is_binary(top_module) and is_list(source_files) and is_binary(wrapper_cpp) and
             is_list(opts) do
    compile(top_module, source_files, wrapper_cpp, Keyword.put(opts, :mode, :build))
  end

  def compile_executable(top_module, source_files, wrapper_cpp, _opts) do
    {:error, {:invalid_arguments, top_module, source_files, wrapper_cpp}}
  end

  @doc """
  Runs Verilator lint-only validation through Docker.

  Lint-only mode stages only the SystemVerilog sources, invokes Verilator with
  `--lint-only`, and returns `{:error, {:verilator_lint_failed, status, log,
  command}}` when Verilator reports diagnostics with a non-zero exit status.
  """
  @spec lint(term(), term(), keyword()) :: {:ok, lint_result()} | {:error, term()}
  def lint(top_module, source_files, opts \\ []) do
    compile(top_module, source_files, nil, Keyword.put(opts, :mode, :lint_only))
  end

  @doc """
  Runs Verilator through Docker in either build or lint-only mode.

  ## Options

    * `:mode` - `:build` or `:lint_only`. Defaults to `:build`.
    * `:docker_mode` - `:run_once` or `:persistent`. Defaults to `:run_once`.
      Persistent mode uses `SvPortSim.Verilator.DockerWorker` and `docker exec`
      to reuse a long-running container.
    * `:image` - Docker image to use. Defaults to `"#{@default_image}"`.
    * `:work_dir` - Host-side build directory. Defaults to
      `default_work_dir(top_module)`. The directory is expanded before use.
    * `:docker` - Docker executable path. When omitted, the executable is
      resolved with `DockerAvailability.executable/0`.
    * `:check_docker` - Whether to check Docker daemon reachability before
      preparing the workspace and running Verilator. Defaults to `true`.
    * `:make_jobs` - Value passed to Verilator's `-j` option in build mode.
      Accepts a non-negative integer or a non-empty string. Defaults to `0`.
    * `:extra_args` - Additional Verilator arguments. Must be a list of strings.
      Defaults to `[]`.
    * `:user` - Docker user option. Defaults to `:current`, which attempts to
      pass the current `uid:gid` to Docker. Use `nil` or `false` to omit
      `--user`, or pass a non-empty string such as `"1000:1000"`.
    * `:clean` - Whether to remove staged `rtl/`, `cpp/`, and `obj_dir/`
      directories before preparing the workspace. Defaults to `true`.
    * `:verify_executable` - Whether to require the expected executable
      `obj_dir/V<top_module>` to exist after Docker finishes successfully in
      build mode. Defaults to `true`.
    * `:docker_worker` - Existing `SvPortSim.Verilator.DockerWorker` pid or
      registered name to use when `docker_mode: :persistent`.
    * `:docker_worker_name` - Container and registry name for persistent mode.
      Defaults to a stable name derived from `work_dir`.
    * `:docker_worker_cleanup` - `:manual` or `:on_exit`. Defaults to `:manual`.

  Build mode returns `{:ok, build}` with `:executable`. Lint-only mode returns
  `{:ok, lint}` without `:executable`.
  """
  @spec compile(term(), term(), term(), keyword()) :: {:ok, compile_result()} | {:error, term()}
  def compile(top_module, source_files, wrapper_cpp, opts \\ [])

  def compile(top_module, source_files, wrapper_cpp, opts)
      when is_binary(top_module) and is_list(source_files) and is_list(opts) do
    with {:ok, mode} <- compile_mode(opts),
         :ok <- validate_top_module(top_module),
         :ok <- validate_source_files(source_files),
         :ok <- validate_wrapper_cpp(mode, wrapper_cpp),
         {:ok, docker} <- docker_executable(opts),
         :ok <- maybe_check_docker(docker, opts),
         {:ok, image} <- image(opts),
         {:ok, make_jobs} <- make_jobs(opts),
         {:ok, extra_args} <- extra_args(opts),
         {:ok, work_dir} <- work_dir(top_module, opts),
         :ok <-
           prepare_workspace(
             work_dir,
             source_files,
             wrapper_cpp,
             mode,
             Keyword.get(opts, :clean, true)
           ) do
      staged_sources = staged_source_paths(source_files)
      staged_wrapper = staged_wrapper_path(wrapper_cpp)

      verilator_args =
        verilator_args(mode, top_module, staged_sources, staged_wrapper, make_jobs, extra_args)

      docker_args = docker_run_args(image, work_dir, verilator_args, opts)

      run_verilator(docker, docker_args, verilator_args, mode, top_module, image, work_dir, opts)
    end
  end

  def compile(top_module, source_files, wrapper_cpp, _opts) do
    {:error, {:invalid_arguments, top_module, source_files, wrapper_cpp}}
  end

  @doc """
  Returns the default host-side Verilator work directory for `top_module`.

  The returned path is application-local and is currently resolved as:

      Application.app_dir(:sv_port_sim, Path.join(["verilator", top_module]))

  For example, the default work directory for `"Counter"` is under the
  application's `verilator/Counter` directory.
  """
  @spec default_work_dir(String.t()) :: Path.t()
  def default_work_dir(top_module) when is_binary(top_module) do
    Application.app_dir(@app, Path.join(["verilator", top_module]))
  end

  defp compile_mode(opts) do
    case Keyword.get(opts, :mode, :build) do
      :build -> {:ok, :build}
      :lint_only -> {:ok, :lint_only}
      mode -> {:error, {:invalid_compile_mode, mode}}
    end
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

  defp maybe_check_docker(docker, opts) do
    if Keyword.get(opts, :check_docker, true) do
      case System.cmd(docker, ["version", "--format", "{{.Server.Version}}"],
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          :ok

        {output, status} ->
          {:error, {:docker_unavailable, status, String.trim(output)}}
      end
    else
      :ok
    end
  rescue
    e in ErlangError ->
      {:error, {:docker_command_failed, 127, Exception.message(e)}}
  end

  defp image(opts) do
    case Keyword.get(opts, :image, @default_image) do
      image when is_binary(image) and byte_size(image) > 0 ->
        {:ok, image}

      image ->
        {:error, {:invalid_image, image}}
    end
  end

  defp make_jobs(opts) do
    case Keyword.get(opts, :make_jobs, 0) do
      jobs when is_integer(jobs) and jobs >= 0 ->
        {:ok, Integer.to_string(jobs)}

      jobs when is_binary(jobs) and byte_size(jobs) > 0 ->
        {:ok, jobs}

      jobs ->
        {:error, {:invalid_make_jobs, jobs}}
    end
  end

  defp extra_args(opts) do
    args = Keyword.get(opts, :extra_args, [])

    if is_list(args) and Enum.all?(args, &is_binary/1) do
      {:ok, args}
    else
      {:error, {:invalid_extra_args, args}}
    end
  end

  defp work_dir(top_module, opts) do
    case persistent_workspace(opts) do
      {:ok, dir} -> normalize_work_dir(dir)
      :default -> normalize_work_dir(Keyword.get(opts, :work_dir, default_work_dir(top_module)))
      {:error, reason} -> {:error, reason}
    end
  end

  defp persistent_workspace(opts) do
    case Keyword.get(opts, :docker_mode, :run_once) do
      :persistent -> persistent_workspace_dir(opts)
      _other -> :default
    end
  end

  defp persistent_workspace_dir(opts) do
    cond do
      worker = Keyword.get(opts, :docker_worker) ->
        persistent_worker_workspace(worker)

      Keyword.has_key?(opts, :docker_worker_workspace) ->
        {:ok, Keyword.fetch!(opts, :docker_worker_workspace)}

      true ->
        :default
    end
  end

  defp persistent_worker_workspace(worker) do
    case DockerWorker.info(worker) do
      {:ok, %{workspace_dir: workspace_dir}} -> {:ok, workspace_dir}
      error -> {:error, {:docker_worker_info_failed, error}}
    end
  end

  defp normalize_work_dir(dir) do
    if is_binary(dir) and byte_size(dir) > 0 do
      {:ok, Path.expand(dir)}
    else
      {:error, {:invalid_work_dir, dir}}
    end
  end

  defp prepare_workspace(work_dir, source_files, wrapper_cpp, mode, clean?) do
    rtl_dir = Path.join(work_dir, "rtl")
    cpp_dir = Path.join(work_dir, "cpp")

    with :ok <- ensure_dir(work_dir),
         :ok <- maybe_clean_workspace(work_dir, clean?),
         :ok <- ensure_dir(rtl_dir),
         :ok <- copy_files(source_files, rtl_dir) do
      prepare_wrapper_workspace(mode, wrapper_cpp, cpp_dir)
    end
  end

  defp prepare_wrapper_workspace(:build, wrapper_cpp, cpp_dir) do
    with :ok <- ensure_dir(cpp_dir) do
      copy_file(wrapper_cpp, cpp_dir)
    end
  end

  defp prepare_wrapper_workspace(:lint_only, _wrapper_cpp, _cpp_dir), do: :ok

  defp maybe_clean_workspace(work_dir, true) do
    Enum.reduce_while(["rtl", "cpp", @obj_dir_name], :ok, fn subdir, :ok ->
      path = Path.join(work_dir, subdir)

      case File.rm_rf(path) do
        {:ok, _files} ->
          {:cont, :ok}

        {:error, reason, file} ->
          {:halt, {:error, {:clean_failed, file, reason}}}
      end
    end)
  end

  defp maybe_clean_workspace(_work_dir, _clean?) do
    :ok
  end

  defp ensure_dir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, path, reason}}
    end
  end

  defp copy_files(files, dest_dir) do
    Enum.reduce_while(files, :ok, fn file, :ok ->
      case copy_file(file, dest_dir) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp copy_file(source, dest_dir) do
    dest = Path.join(dest_dir, Path.basename(source))

    case File.cp(source, dest) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, {:copy_failed, source, dest, reason}}
    end
  end

  defp verilator_args(:build, top_module, staged_sources, staged_wrapper, make_jobs, extra_args) do
    [
      "--cc",
      "--exe",
      "--build",
      "-j",
      make_jobs,
      "--Mdir",
      @obj_dir_name,
      "--top-module",
      top_module
    ] ++
      extra_args ++
      [staged_wrapper] ++ staged_sources
  end

  defp verilator_args(
         :lint_only,
         top_module,
         staged_sources,
         _staged_wrapper,
         _make_jobs,
         extra_args
       ) do
    [
      "--lint-only",
      "--Mdir",
      @obj_dir_name,
      "--top-module",
      top_module
    ] ++
      extra_args ++ staged_sources
  end

  defp docker_run_args(image, work_dir, verilator_args, opts) do
    [
      "run",
      "--rm"
    ] ++
      docker_user_args(Keyword.get(opts, :user, :current)) ++
      [
        "--mount",
        "type=bind,source=#{work_dir},target=#{@container_work_dir}",
        "--workdir",
        @container_work_dir,
        image
      ] ++ verilator_args
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

  defp run_verilator(docker, docker_args, verilator_args, mode, top_module, image, work_dir, opts) do
    case Keyword.get(opts, :docker_mode, :run_once) do
      :run_once ->
        {log, status} = System.cmd(docker, docker_args, stderr_to_stdout: true)
        command = [docker | docker_args]

        finalize_verilator_result(%{
          status: status,
          log: log,
          command: command,
          mode: mode,
          top_module: top_module,
          image: image,
          docker: docker,
          work_dir: work_dir,
          opts: opts,
          extra: %{}
        })

      :persistent ->
        with {:ok, worker} <- docker_worker(docker, image, work_dir, opts),
             {:ok, exec} <-
               DockerWorker.run(worker, verilator_args,
                 timeout: Keyword.get(opts, :timeout, :infinity)
               ) do
          finalize_verilator_result(%{
            status: exec.status,
            log: exec.log,
            command: exec.command,
            mode: mode,
            top_module: top_module,
            image: image,
            docker: exec.docker,
            work_dir: exec.workspace_dir,
            opts: opts,
            extra: %{
              container_name: exec.container_name,
              container_id: exec.container_id
            }
          })
        end

      docker_mode ->
        {:error, {:invalid_docker_mode, docker_mode}}
    end
  rescue
    e in ErlangError ->
      {:error, {:docker_run_failed, Exception.message(e)}}
  end

  defp finalize_verilator_result(context) do
    status = Map.fetch!(context, :status)
    log = Map.fetch!(context, :log)
    command = Map.fetch!(context, :command)
    mode = Map.fetch!(context, :mode)
    top_module = Map.fetch!(context, :top_module)
    work_dir = Map.fetch!(context, :work_dir)
    trimmed_log = String.trim(log)
    obj_dir = Path.join(work_dir, @obj_dir_name)
    executable = Path.join(obj_dir, "V#{top_module}")

    cond do
      status != 0 and mode == :lint_only ->
        {:error, {:verilator_lint_failed, status, trimmed_log, command}}

      status != 0 ->
        {:error, {:verilator_docker_failed, status, trimmed_log, command}}

      mode == :build and verify_executable?(context) and not File.exists?(executable) ->
        {:error, {:executable_not_found, executable, trimmed_log, command}}

      mode == :build ->
        {:ok, build_result(context, obj_dir, executable)}

      mode == :lint_only ->
        {:ok, lint_result(context, obj_dir)}
    end
  end

  defp verify_executable?(context) do
    context
    |> Map.fetch!(:opts)
    |> Keyword.get(:verify_executable, true)
  end

  defp build_result(context, obj_dir, executable) do
    context
    |> base_result(:build, obj_dir)
    |> Map.put(:executable, executable)
  end

  defp lint_result(context, obj_dir) do
    base_result(context, :lint_only, obj_dir)
  end

  defp base_result(context, mode, obj_dir) do
    %{
      mode: mode,
      top_module: Map.fetch!(context, :top_module),
      image: Map.fetch!(context, :image),
      docker: Map.fetch!(context, :docker),
      work_dir: Map.fetch!(context, :work_dir),
      obj_dir: obj_dir,
      command: Map.fetch!(context, :command),
      log: Map.fetch!(context, :log)
    }
    |> Map.merge(Map.fetch!(context, :extra))
  end

  defp docker_worker(docker, image, work_dir, opts) do
    case Keyword.get(opts, :docker_worker) do
      nil ->
        worker_name =
          Keyword.get_lazy(opts, :docker_worker_name, fn -> default_worker_name(work_dir) end)

        DockerWorker.start_or_reuse(
          docker: docker,
          image: image,
          workspace_dir: Keyword.get(opts, :docker_worker_workspace, work_dir),
          container_name: worker_name,
          docker_worker_name: worker_name,
          user: Keyword.get(opts, :user, :current),
          reuse: Keyword.get(opts, :docker_worker_reuse, true),
          cleanup: Keyword.get(opts, :docker_worker_cleanup, :manual)
        )

      worker ->
        {:ok, worker}
    end
  end

  defp default_worker_name(work_dir) do
    suffix =
      work_dir
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "sv_port_sim_verilator_#{suffix}"
  end

  defp staged_source_paths(source_files) do
    Enum.map(source_files, fn source ->
      Path.join("rtl", Path.basename(source))
    end)
  end

  defp staged_wrapper_path(wrapper_cpp) when is_binary(wrapper_cpp) do
    Path.join("cpp", Path.basename(wrapper_cpp))
  end

  defp staged_wrapper_path(_wrapper_cpp), do: nil

  defp validate_top_module(top_module) do
    if Regex.match?(@sv_identifier, top_module) do
      :ok
    else
      {:error, {:invalid_top_module, top_module}}
    end
  end

  defp validate_source_files([]), do: {:error, :empty_source_files}

  defp validate_source_files(source_files) do
    validate_source_file_list(source_files)
    |> then_ok(fn -> validate_unique_source_basenames(source_files) end)
    |> then_ok(fn -> validate_regular_source_files(source_files) end)
  end

  defp then_ok(:ok, fun) when is_function(fun, 0), do: fun.()
  defp then_ok({:error, _reason} = error, _fun), do: error

  defp validate_source_file_list(source_files) do
    if Enum.all?(source_files, &is_binary/1) do
      :ok
    else
      {:error, {:invalid_source_files, source_files}}
    end
  end

  defp validate_unique_source_basenames(source_files) do
    basenames = Enum.map(source_files, &Path.basename/1)

    if basenames == Enum.uniq(basenames) do
      :ok
    else
      {:error, {:duplicate_source_basenames, basenames}}
    end
  end

  defp validate_regular_source_files(source_files) do
    Enum.reduce_while(source_files, :ok, &validate_regular_source_file/2)
  end

  defp validate_regular_source_file(source, :ok) do
    case validate_regular_file(source, :source_not_found) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp validate_wrapper_cpp(:build, wrapper_cpp) when is_binary(wrapper_cpp) do
    validate_regular_file(wrapper_cpp, :wrapper_not_found)
  end

  defp validate_wrapper_cpp(:build, wrapper_cpp),
    do: {:error, {:invalid_wrapper_cpp, wrapper_cpp}}

  defp validate_wrapper_cpp(:lint_only, _wrapper_cpp), do: :ok

  defp validate_regular_file(path, tag) do
    if File.regular?(path) do
      :ok
    else
      {:error, {tag, path}}
    end
  end
end
