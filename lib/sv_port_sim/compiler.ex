defmodule SvPortSim.Compiler do
  @moduledoc """
  Coordinates the high-level build pipeline for Verilated SystemVerilog modules.

  This module is a convenience facade over the lower-level build steps provided
  by this package:

    * `SvPortSim.Rtl.expand/2` writes in-memory SystemVerilog sources to RTL files.
    * `SvPortSim.Verilator.Wrapper.write/2` or `write/3` generates and writes
      the C++ wrapper source.
    * `SvPortSim.Verilator.Docker.compile_executable/4` builds the Verilated
      executable through Docker.

  `compile/3` is intended for callers that have SystemVerilog source strings in
  memory and want a single call to produce a Verilator executable. The current
  implementation supports the Docker backend only. This module writes files to
  disk and, by default, invokes Docker. It does not run simulations, manage
  simulation processes, or communicate with generated executables through ports.
  """

  alias SvPortSim.Rtl
  alias SvPortSim.Verilator.Docker, as: VerilatorDocker
  alias SvPortSim.Verilator.Wrapper

  @type compile_result :: %{
          top_module: String.t(),
          rtl: map(),
          wrapper: %{file: Path.t()},
          build: map(),
          executable: Path.t()
        }

  @doc """
  Compiles SystemVerilog sources into a Verilated executable.

  `top_module` is the SystemVerilog top-module name. `sources` is a map from
  module names to SystemVerilog source strings. The source map is validated and
  written by `SvPortSim.Rtl.expand/2`.

  Compilation performs the following steps in order:

    1. expands the SystemVerilog source map into RTL files
    2. writes a generated C++ wrapper for `top_module`
    3. invokes the selected backend to build the Verilated executable

  The current implementation supports only the Docker backend.

  ## Options

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

  All other options are forwarded to
  `SvPortSim.Verilator.Docker.compile_executable/4` when the Docker backend is
  used. Pipeline-only options such as `:backend`, `:wrapper_dir`,
  `:signal_specs`, and `:verilator_args` are not forwarded.

  When passing additional Verilator arguments through this facade, use
  `:verilator_args` instead of `:extra_args`.

  ## Return value

  Returns `{:ok, result}` on success. The returned `result` map contains:

    * `:top_module` - the top-module name passed to this function
    * `:rtl` - the result returned by `SvPortSim.Rtl.expand/2`
    * `:wrapper` - a map containing the generated wrapper file path
    * `:build` - the backend build result
    * `:executable` - the generated executable path

  Returns `{:error, reason}` on failure.
  """
  @spec compile(term(), term(), keyword()) :: {:ok, compile_result()} | {:error, term()}
  def compile(top_module, sources, opts \\ [])

  def compile(top_module, sources, opts)
      when is_binary(top_module) and is_map(sources) and is_list(opts) do
    with {:ok, rtl} <- Rtl.expand(top_module, sources),
         {:ok, wrapper_dir} <- wrapper_dir(top_module, opts),
         {:ok, wrapper_file} <- write_wrapper(top_module, wrapper_dir, opts),
         {:ok, build} <- compile_with_backend(top_module, rtl.files, wrapper_file, opts) do
      {:ok,
       %{
         top_module: top_module,
         rtl: rtl,
         wrapper: %{file: wrapper_file},
         build: build,
         executable: build.executable
       }}
    end
  end

  def compile(top_module, sources, _opts), do: {:error, {:invalid_arguments, top_module, sources}}

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

  defp compile_with_backend(top_module, rtl_files, wrapper_file, opts) do
    backend = Keyword.get(opts, :backend, :docker)

    case backend do
      :docker ->
        docker_opts =
          opts
          |> Keyword.drop([:backend, :wrapper_dir, :signal_specs, :verilator_args])
          |> Keyword.put(:extra_args, Keyword.get(opts, :verilator_args, []))

        VerilatorDocker.compile_executable(
          top_module,
          Map.values(rtl_files),
          wrapper_file,
          docker_opts
        )

      other ->
        {:error, {:unsupported_backend, other}}
    end
  end
end
