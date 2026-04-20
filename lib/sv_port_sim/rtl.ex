defmodule SvPortSim.Rtl do
  @moduledoc """
  Utilities for expanding SystemVerilog source strings into the RTL directory.
  """

  @app :sv_port_sim
  @rtl_subdir "rtl"

  # Minimal support for SystemVerilog simple identifiers.
  #
  # Escaped identifiers such as \foo-bar are intentionally not supported yet,
  # because they are awkward and unsafe to use directly as file names.
  @sv_identifier ~r/\A[A-Za-z_][A-Za-z0-9_$]*\z/

  @type module_name :: String.t()
  @type sv_source :: String.t()
  @type source_map :: %{required(module_name()) => sv_source()}

  @type expand_result :: %{
          top_module: module_name(),
          rtl_dir: Path.t(),
          files: %{module_name() => Path.t()}
        }

  @doc """
  Expands SystemVerilog source strings into `Application.app_dir(:sv_port_sim, "rtl")`.

  `top_module` must be included as a key in `sources`.

  Each entry in `sources` is written as:

      <module_name>.sv

  For example:

      SvPortSim.Rtl.expand("Counter", %{
        "Counter" => "module Counter(...); endmodule",
        "SubMod" => "module SubMod(...); endmodule"
      })

  returns:

      {:ok,
       %{
         top_module: "Counter",
         rtl_dir: ".../sv_port_sim/rtl",
         files: %{
           "Counter" => ".../sv_port_sim/rtl/Counter.sv",
           "SubMod" => ".../sv_port_sim/rtl/SubMod.sv"
         }
       }}
  """
  @spec expand(module_name(), source_map()) :: {:ok, expand_result()} | {:error, term()}
  def expand(top_module, sources) when is_binary(top_module) and is_map(sources) do
    with :ok <- validate_sources(sources),
         :ok <- validate_top_module(top_module, sources),
         rtl_dir = rtl_dir(),
         :ok <- ensure_rtl_dir(rtl_dir),
         {:ok, files} <- write_sources(rtl_dir, sources) do
      {:ok,
       %{
         top_module: top_module,
         rtl_dir: rtl_dir,
         files: files
       }}
    end
  end

  def expand(top_module, sources) do
    {:error, {:invalid_arguments, top_module, sources}}
  end

  @doc """
  Returns the RTL output directory.

  This is currently:

      Application.app_dir(:sv_port_sim, "rtl")
  """
  @spec rtl_dir() :: Path.t()
  def rtl_dir() do
    Application.app_dir(@app, @rtl_subdir)
  end

  @doc """
  Builds the SystemVerilog source file name for a module name.

      iex> SvPortSim.Rtl.source_filename("Counter")
      {:ok, "Counter.sv"}

  """
  @spec source_filename(module_name()) :: {:ok, String.t()} | {:error, term()}
  def source_filename(module_name) when is_binary(module_name) do
    with :ok <- validate_module_name(module_name) do
      {:ok, module_name <> ".sv"}
    end
  end

  def source_filename(module_name) do
    {:error, {:invalid_module_name, module_name}}
  end

  @doc """
  Bang variant of `source_filename/1`.
  """
  @spec source_filename!(module_name()) :: String.t()
  def source_filename!(module_name) do
    case source_filename(module_name) do
      {:ok, filename} ->
        filename

      {:error, reason} ->
        raise ArgumentError, message: inspect(reason)
    end
  end

  defp ensure_rtl_dir(rtl_dir) do
    case File.mkdir_p(rtl_dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, rtl_dir, reason}}
    end
  end

  defp write_sources(rtl_dir, sources) do
    Enum.reduce_while(sources, {:ok, %{}}, fn {module_name, source}, {:ok, files} ->
      case write_source(rtl_dir, module_name, source) do
        {:ok, file_path} ->
          {:cont, {:ok, Map.put(files, module_name, file_path)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp write_source(rtl_dir, module_name, source) do
    with {:ok, filename} <- source_filename(module_name) do
      file_path = Path.join(rtl_dir, filename)

      case File.write(file_path, source) do
        :ok ->
          {:ok, file_path}

        {:error, reason} ->
          {:error, {:write_failed, module_name, file_path, reason}}
      end
    end
  end

  defp validate_sources(sources) when map_size(sources) == 0 do
    {:error, :empty_sources}
  end

  defp validate_sources(sources) do
    Enum.reduce_while(sources, :ok, fn
      {module_name, source}, :ok when is_binary(module_name) and is_binary(source) ->
        case validate_module_name(module_name) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {module_name, source}, :ok ->
        {:halt, {:error, {:invalid_source_entry, module_name, source}}}
    end)
  end

  defp validate_top_module(top_module, sources) do
    with :ok <- validate_module_name(top_module) do
      if Map.has_key?(sources, top_module) do
        :ok
      else
        {:error, {:top_module_not_found, top_module}}
      end
    end
  end

  defp validate_module_name(module_name) when is_binary(module_name) do
    if Regex.match?(@sv_identifier, module_name) do
      :ok
    else
      {:error, {:invalid_module_name, module_name}}
    end
  end

  defp validate_module_name(module_name) do
    {:error, {:invalid_module_name, module_name}}
  end
end
