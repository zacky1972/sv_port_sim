defmodule SvPortSim.Compiler do
  @moduledoc """
  High-level compiler pipeline for building Verilated SystemVerilog modules.
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

  @spec compile(term(), term(), keyword()) :: {:ok, compile_result()} | {:error, term()}
  def compile(top_module, sources, opts \\ [])

  def compile(top_module, sources, opts)
      when is_binary(top_module) and is_map(sources) and is_list(opts) do
    with {:ok, rtl} <- Rtl.expand(top_module, sources),
         {:ok, wrapper_dir} <- wrapper_dir(top_module, opts),
         {:ok, wrapper_file} <- Wrapper.write(top_module, wrapper_dir),
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

  def compile(top_module, sources, _opts) do
    {:error, {:invalid_arguments, top_module, sources}}
  end

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

  defp compile_with_backend(top_module, rtl_files, wrapper_file, opts) do
    backend = Keyword.get(opts, :backend, :docker)

    case backend do
      :docker ->
        docker_opts =
          opts
          |> Keyword.drop([:backend, :wrapper_dir, :verilator_args])
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
