defmodule SvPortSim.Compiler do
  @moduledoc """
  Coordinates the high-level build pipeline for generated SystemVerilog modules.

  This module is a convenience facade over the lower-level build steps provided
  by this package:

    * `SvPortSim.Rtl.expand/2` writes in-memory SystemVerilog sources to RTL files.
    * `SvPortSim.Verilator.Wrapper.write/2` or `write/3` generates and writes
      the C++ wrapper source.
    * `SvPortSim.Verilator.Docker.compile/4` validates or builds the generated
      design through Docker.

  `compile/3` defaults to `mode: :build`, preserving the existing behavior that
  produces a Verilated executable. `mode: :lint_only`, or the `lint/3` helper,
  runs Verilator in a lighter validation mode that does not require or return a
  runnable executable.
  """

  alias SvPortSim.Compiler.Cache
  alias SvPortSim.Rtl
  alias SvPortSim.Verilator.Docker, as: VerilatorDocker
  alias SvPortSim.Verilator.Wrapper

  @type compile_mode :: :build | :lint_only

  @type compile_result :: %{
          required(:top_module) => String.t(),
          required(:mode) => compile_mode(),
          required(:rtl) => map(),
          required(:wrapper) => %{file: Path.t()},
          required(:build) => map(),
          optional(:executable) => Path.t()
        }

  @doc """
  Validates generated SystemVerilog sources with Verilator lint-only mode.

  This is equivalent to calling `compile/3` with `mode: :lint_only`. The wrapper
  source is still generated so that signal metadata is validated consistently,
  but the Docker backend invokes Verilator with `--lint-only` and the returned
  result does not contain `:executable`.
  """
  @spec lint(term(), term(), keyword()) :: {:ok, compile_result()} | {:error, term()}
  def lint(top_module, sources, opts \\ [])

  def lint(top_module, sources, opts) when is_list(opts) do
    compile(top_module, sources, Keyword.put(opts, :mode, :lint_only))
  end

  def lint(top_module, sources, opts) do
    {:error, {:invalid_arguments, top_module, sources, opts}}
  end

  @doc """
  Compiles or validates SystemVerilog sources through the selected backend.

  `top_module` is the SystemVerilog top-module name. `sources` is a map from
  module names to SystemVerilog source strings. The source map is validated and
  written by `SvPortSim.Rtl.expand/2`.

  Compilation performs the following steps in order:

    1. expands the SystemVerilog source map into RTL files
    2. writes a generated C++ wrapper for `top_module`
    3. invokes the selected backend in `:build` or `:lint_only` mode

  The current implementation supports only the Docker backend.

  ## Options

    * `:mode` - `:build` or `:lint_only`. Defaults to `:build`.
    * `:backend` - Backend to use. Defaults to `:docker`. Any value other than
      `:docker` returns `{:error, {:unsupported_backend, backend}}`.
    * `:wrapper_dir` - Directory where the generated C++ wrapper is written.
      Defaults to `Application.app_dir(:sv_port_sim, Path.join(["wrapper", top_module]))`.
      The directory path is expanded before use.
    * `:signal_specs` - Optional list of `SvPortSim.SignalSpec` metadata maps.
      When present, the generated wrapper includes `poke` and `peek` accessors
      for supported top-level Verilated fields.
    * `:verilator_args` - Additional Verilator arguments. These are converted to
      the Docker backend's `:extra_args` option. Defaults to `[]`.
    * `:cache` - When `true`, successful backend results are stored in and
      retrieved from a content-addressed cache. Defaults to `false`.
    * `:cache_dir` - Cache root used when `cache: true`. Defaults to
      `"_build/sv_port_sim/cache"`.

  All other options are forwarded to `SvPortSim.Verilator.Docker.compile/4` when
  the Docker backend is used. Pipeline-only options such as `:backend`,
  `:wrapper_dir`, `:signal_specs`, `:verilator_args`, `:cache`, and `:cache_dir`
  are not forwarded.

  ## Return value

  Returns `{:ok, result}` on success. The returned `result` map contains:

    * `:top_module` - the top-module name passed to this function
    * `:mode` - `:build` or `:lint_only`
    * `:rtl` - the result returned by `SvPortSim.Rtl.expand/2`
    * `:wrapper` - a map containing the generated wrapper file path
    * `:build` - the backend build or lint result
    * `:executable` - the generated executable path, only in `:build` mode

  Returns `{:error, reason}` on failure.
  """
  @spec compile(term(), term(), keyword()) :: {:ok, compile_result()} | {:error, term()}
  def compile(top_module, sources, opts \\ [])

  def compile(top_module, sources, opts)
      when is_binary(top_module) and is_map(sources) and is_list(opts) do
    with {:ok, mode} <- compile_mode(opts),
         {:ok, rtl} <- Rtl.expand(top_module, sources),
         {:ok, wrapper_dir} <- wrapper_dir(top_module, opts),
         {:ok, wrapper_file} <- write_wrapper(top_module, wrapper_dir, opts),
         {:ok, build} <-
           compile_with_backend(top_module, sources, rtl.files, wrapper_file, mode, opts) do
      result = %{
        top_module: top_module,
        mode: mode,
        rtl: rtl,
        wrapper: %{file: wrapper_file},
        build: build
      }

      {:ok, maybe_put_executable(result, build)}
    end
  end

  def compile(top_module, sources, _opts), do: {:error, {:invalid_arguments, top_module, sources}}

  defp compile_mode(opts) do
    case Keyword.get(opts, :mode, :build) do
      :build -> {:ok, :build}
      :lint_only -> {:ok, :lint_only}
      other -> {:error, {:unsupported_compile_mode, other}}
    end
  end

  defp maybe_put_executable(result, %{executable: executable}) when is_binary(executable) do
    Map.put(result, :executable, executable)
  end

  defp maybe_put_executable(result, _build), do: result

  defp wrapper_dir(top_module, opts) do
    dir =
      Keyword.get_lazy(opts, :wrapper_dir, fn ->
        Application.app_dir(:sv_port_sim, Path.join(["wrapper", top_module]))
      end)

    if is_binary(dir) do
      {:ok, Path.expand(dir)}
    else
      {:error, {:invalid_wrapper_dir, dir}}
    end
  end

  defp write_wrapper(top_module, wrapper_dir, opts) do
    case Keyword.fetch(opts, :signal_specs) do
      :error -> Wrapper.write(top_module, wrapper_dir)
      {:ok, signal_specs} -> Wrapper.write(top_module, wrapper_dir, signal_specs)
    end
  end

  defp compile_with_backend(top_module, sources, rtl_files, wrapper_file, mode, opts) do
    case Keyword.get(opts, :backend, :docker) do
      :docker -> compile_with_docker(top_module, sources, rtl_files, wrapper_file, mode, opts)
      other -> {:error, {:unsupported_backend, other}}
    end
  end

  defp compile_with_docker(top_module, sources, rtl_files, wrapper_file, mode, opts) do
    docker_opts = docker_opts(opts, mode)
    cache_context = cache_context(top_module, sources, wrapper_file, mode, opts)

    Cache.fetch_or_run(cache_context, opts, fn cache_entry_dir ->
      run_docker_compile(top_module, rtl_files, wrapper_file, docker_opts, cache_entry_dir)
    end)
  end

  defp docker_opts(opts, mode) do
    opts
    |> Keyword.drop([
      :backend,
      :wrapper_dir,
      :signal_specs,
      :verilator_args,
      :cache,
      :cache_dir
    ])
    |> Keyword.put(:extra_args, Keyword.get(opts, :verilator_args, []))
    |> Keyword.put(:mode, mode)
  end

  defp cache_context(top_module, sources, wrapper_file, mode, opts) do
    %{
      backend: :docker,
      docker_mode: Keyword.get(opts, :docker_mode, :run_once),
      mode: mode,
      top_module: top_module,
      sources: sources,
      wrapper_file: wrapper_file,
      signal_specs: Keyword.get(opts, :signal_specs, []),
      image: Keyword.get(opts, :image, "verilator/verilator:latest"),
      verilator_args: Keyword.get(opts, :verilator_args, []),
      make_jobs: Keyword.get(opts, :make_jobs, 0)
    }
  end

  defp run_docker_compile(top_module, rtl_files, wrapper_file, docker_opts, cache_entry_dir) do
    effective_opts = maybe_put_cache_work_dir(docker_opts, cache_entry_dir)

    VerilatorDocker.compile(
      top_module,
      sorted_source_files(rtl_files),
      wrapper_file,
      effective_opts
    )
  end

  defp maybe_put_cache_work_dir(opts, nil), do: opts

  defp maybe_put_cache_work_dir(opts, cache_entry_dir) do
    if Keyword.has_key?(opts, :docker_worker) do
      opts
    else
      Keyword.put(opts, :work_dir, Path.join(cache_entry_dir, "work"))
    end
  end

  defp sorted_source_files(rtl_files) do
    rtl_files
    |> Enum.sort_by(fn {module_name, _path} -> module_name end)
    |> Enum.map(fn {_module_name, path} -> path end)
  end
end
