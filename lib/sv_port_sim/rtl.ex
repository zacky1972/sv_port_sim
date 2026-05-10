defmodule SvPortSim.Rtl do
  @moduledoc """
  Expands SystemVerilog source strings into RTL source files.

  This module writes in-memory SystemVerilog sources to the application's RTL
  output directory. Each source entry is keyed by its module name and is written
  as a `<module_name>.sv` file.

  `expand/2` is the main entry point. It validates the top-module name, validates
  all source entries, creates the RTL output directory if needed, and writes all
  source files into that directory.

  Module names are intentionally limited to a safe identifier subset: the name
  must start with an ASCII letter or underscore, followed by ASCII letters,
  digits, underscores, or dollar signs. Escaped SystemVerilog identifiers are
  not supported because module names are also used directly as file names.

  The functions in this module write files to disk, but they do not invoke
  Verilator, compile generated files, or run a simulation.
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
  Expands SystemVerilog source strings into the RTL output directory.

  `top_module` must be a valid module name and must exist as a key in `sources`.
  Each entry in `sources` must have a valid module name as its key and a source
  string as its value.

  The output directory is resolved by `rtl_dir/0`. Each source entry is written
  directly under that directory by using the filename returned by
  `source_filename/1`. Existing files with the same names are overwritten.

  Returns `{:ok, result}` on success. The returned map contains:

    * `:top_module` - the top-module name passed to this function
    * `:rtl_dir` - the RTL output directory
    * `:files` - a map from module names to written file paths

  Returns one of the following error tuples:

    * `{:error, {:invalid_arguments, top_module, sources}}` when `top_module`
      is not a binary or `sources` is not a map
    * `{:error, :empty_sources}` when `sources` is an empty map
    * `{:error, {:invalid_source_entry, module_name, source}}` when a source
      entry does not have a binary module name and a binary source string
    * `{:error, {:invalid_module_name, module_name}}` when a module name does
      not satisfy the accepted identifier format
    * `{:error, {:top_module_not_found, top_module}}` when `sources` does not
      contain `top_module`
    * `{:error, {:mkdir_failed, rtl_dir, reason}}` when creating the RTL output
      directory fails
    * `{:error, {:write_failed, module_name, file_path, reason}}` when writing
      a source file fails

  ## Example

      sources = %{
        "Counter" => "module Counter; endmodule",
        "SubMod" => "module SubMod; endmodule"
      }

      {:ok, result} = SvPortSim.Rtl.expand("Counter", sources)

      result.top_module
      #=> "Counter"

      Map.keys(result.files)
      #=> ["Counter", "SubMod"]
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

  The directory is currently resolved as:

      Application.app_dir(:sv_port_sim, "rtl")

  `expand/2` creates this directory before writing source files. This function
  only returns the path; it does not create the directory.
  """
  @spec rtl_dir() :: Path.t()
  def rtl_dir() do
    Application.app_dir(@app, @rtl_subdir)
  end

  @doc """
  Builds the SystemVerilog source filename for `module_name`.

  The filename is formed by appending `.sv` to the validated module name.

  Returns `{:ok, filename}` on success.

  Returns `{:error, {:invalid_module_name, module_name}}` when `module_name` is
  not a binary or does not satisfy the accepted identifier format.

  ## Examples

      iex> SvPortSim.Rtl.source_filename("Counter")
      {:ok, "Counter.sv"}

      iex> SvPortSim.Rtl.source_filename("../Counter")
      {:error, {:invalid_module_name, "../Counter"}}

      iex> SvPortSim.Rtl.source_filename(123)
      {:error, {:invalid_module_name, 123}}
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
  Builds the SystemVerilog source filename for `module_name`, raising on error.

  This is the bang variant of `source_filename/1`.

  Returns the filename when `module_name` is valid.

  Raises `ArgumentError` when `module_name` is not a binary or does not satisfy
  the accepted identifier format.

  ## Examples

      iex> SvPortSim.Rtl.source_filename!("Counter")
      "Counter.sv"

      iex> SvPortSim.Rtl.source_filename!("../Counter")
      ** (ArgumentError) {:invalid_module_name, "../Counter"}
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
end
