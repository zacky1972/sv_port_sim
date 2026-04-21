defmodule SvPortSim.Verilator.Docker do
  @moduledoc """
  Runs Verilator inside Docker and builds a Verilated executable.

  This module expects a generated C++ wrapper file and one or more
  SystemVerilog source files. It stages them into a Docker-mounted work
  directory, then invokes the Verilator Docker image.
  """

  alias SvPortSim.Docker, as: DockerProbe

  @app :sv_port_sim
  @default_image "verilator/verilator:latest"
  @container_work_dir "/work"
  @obj_dir_name "obj_dir"

  # Minimal support for SystemVerilog simple identifiers.
  @sv_identifier ~r/\A[A-Za-z_][A-Za-z0-9_$]*\z/

  @type build_result :: %{
          top_module: String.t(),
          image: String.t(),
          docker: Path.t(),
          work_dir: Path.t(),
          obj_dir: Path.t(),
          executable: Path.t(),
          command: [String.t()],
          log: String.t()
        }

  @doc """
  Compiles a Verilated executable by running Verilator in Docker.

  ## Options

    * `:image` - Docker image to use. Defaults to `"#{@default_image}"`.
    * `:work_dir` - Host-side build directory.
      Defaults to `Application.app_dir(:sv_port_sim, "verilator/<top_module>")`.
    * `:docker` - Docker executable path. Defaults to `System.find_executable("docker")`.
    * `:check_docker` - Whether to check Docker daemon reachability before running.
      Defaults to `true`.
    * `:make_jobs` - Value passed to `-j`. Defaults to `0`.
    * `:extra_args` - Extra Verilator arguments, for example `["-Wall"]`.
    * `:user` - Docker user option. Defaults to `:current`.
      Accepts `:current`, `nil`, `false`, or a string such as `"1000:1000"`.
    * `:clean` - Whether to clean staged `rtl`, `cpp`, and `obj_dir` directories first.
      Defaults to `true`.
    * `:verify_executable` - Whether to require the expected executable to exist.
      Defaults to `true`.

  ## Example

      {:ok, build} =
        SvPortSim.Verilator.Docker.compile_executable(
          "Counter",
          ["_build/dev/lib/sv_port_sim/rtl/Counter.sv"],
          "priv/cpp/counter_wrapper.cpp",
          extra_args: ["-Wall"]
        )

      build.executable
      #=> ".../obj_dir/VCounter"
  """
  @spec compile_executable(term(), term(), term(), keyword()) ::
          {:ok, build_result()} | {:error, term()}
  def compile_executable(top_module, source_files, wrapper_cpp, opts \\ [])

  def compile_executable(top_module, source_files, wrapper_cpp, opts)
      when is_binary(top_module) and is_list(source_files) and is_binary(wrapper_cpp) and
             is_list(opts) do
    with :ok <- validate_top_module(top_module),
         :ok <- validate_source_files(source_files),
         :ok <- validate_regular_file(wrapper_cpp, :wrapper_not_found),
         {:ok, docker} <- docker_executable(opts),
         :ok <- maybe_check_docker(docker, opts),
         {:ok, image} <- image(opts),
         {:ok, make_jobs} <- make_jobs(opts),
         {:ok, extra_args} <- extra_args(opts),
         {:ok, work_dir} <- work_dir(top_module, opts),
         :ok <-
           prepare_workspace(work_dir, source_files, wrapper_cpp, Keyword.get(opts, :clean, true)) do
      staged_sources = staged_source_paths(source_files)
      staged_wrapper = staged_wrapper_path(wrapper_cpp)

      args =
        docker_args(
          image,
          work_dir,
          top_module,
          staged_sources,
          staged_wrapper,
          make_jobs,
          extra_args,
          opts
        )

      run_docker(docker, args, top_module, image, work_dir, opts)
    end
  end

  def compile_executable(top_module, source_files, wrapper_cpp, _opts) do
    {:error, {:invalid_arguments, top_module, source_files, wrapper_cpp}}
  end

  @doc """
  Returns the default host-side build directory for a top module.
  """
  @spec default_work_dir(String.t()) :: Path.t()
  def default_work_dir(top_module) when is_binary(top_module) do
    Application.app_dir(@app, Path.join(["verilator", top_module]))
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
    dir = Keyword.get(opts, :work_dir, default_work_dir(top_module))

    if is_binary(dir) and byte_size(dir) > 0 do
      {:ok, Path.expand(dir)}
    else
      {:error, {:invalid_work_dir, dir}}
    end
  end

  defp prepare_workspace(work_dir, source_files, wrapper_cpp, clean?) do
    with :ok <- ensure_dir(work_dir),
         :ok <- maybe_clean_workspace(work_dir, clean?),
         rtl_dir = Path.join(work_dir, "rtl"),
         cpp_dir = Path.join(work_dir, "cpp"),
         :ok <- ensure_dir(rtl_dir),
         :ok <- ensure_dir(cpp_dir),
         :ok <- copy_files(source_files, rtl_dir) do
      copy_file(wrapper_cpp, cpp_dir)
    end
  end

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

  defp docker_args(
         image,
         work_dir,
         top_module,
         staged_sources,
         staged_wrapper,
         make_jobs,
         extra_args,
         opts
       ) do
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
        image,
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

  defp run_docker(docker, args, top_module, image, work_dir, opts) do
    {log, status} = System.cmd(docker, args, stderr_to_stdout: true)

    obj_dir = Path.join(work_dir, @obj_dir_name)
    executable = Path.join(obj_dir, "V#{top_module}")
    command = [docker | args]

    cond do
      status != 0 ->
        {:error, {:verilator_docker_failed, status, String.trim(log), command}}

      Keyword.get(opts, :verify_executable, true) and not File.exists?(executable) ->
        {:error, {:executable_not_found, executable, String.trim(log), command}}

      true ->
        {:ok,
         %{
           top_module: top_module,
           image: image,
           docker: docker,
           work_dir: work_dir,
           obj_dir: obj_dir,
           executable: executable,
           command: command,
           log: log
         }}
    end
  rescue
    e in ErlangError ->
      {:error, {:docker_run_failed, Exception.message(e)}}
  end

  defp staged_source_paths(source_files) do
    Enum.map(source_files, fn source ->
      Path.join("rtl", Path.basename(source))
    end)
  end

  defp staged_wrapper_path(wrapper_cpp) do
    Path.join("cpp", Path.basename(wrapper_cpp))
  end

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

  defp validate_regular_file(path, tag) do
    if File.regular?(path) do
      :ok
    else
      {:error, {tag, path}}
    end
  end
end
