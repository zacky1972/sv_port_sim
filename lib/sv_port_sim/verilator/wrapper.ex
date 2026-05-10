defmodule SvPortSim.Verilator.Wrapper do
  @moduledoc """
  Builds minimal C++ wrapper files for Verilated SystemVerilog top modules.

  This module generates the small C++ program used to instantiate a
  Verilator-generated top-module class, run one `eval()` call, call `final()`,
  and exit. The generated wrapper is intended for compilation and smoke-test
  purposes, not for driving a full simulation.

  The `top_module` argument is the SystemVerilog top-module name without
  Verilator's `V` class-name prefix. For example, `"Counter"` maps to the
  Verilator-generated class `VCounter` and to the wrapper file
  `Counter_wrapper.cpp`.

  Accepted top-module names are limited to a safe identifier subset: the name
  must start with an ASCII letter or underscore, followed by ASCII letters,
  digits, underscores, or dollar signs.
  """

  @sv_identifier ~r/\A[A-Za-z_][A-Za-z0-9_$]*\z/

  @type top_module :: String.t()

  @doc """
  Returns the default C++ wrapper filename for `top_module`.

  The filename is formed by appending `_wrapper.cpp` to the validated
  top-module name.

  Returns `{:ok, filename}` on success.

  Returns `{:error, {:invalid_top_module, top_module}}` when `top_module` is
  not a binary or does not satisfy the accepted identifier format.

  ## Examples

      iex> SvPortSim.Verilator.Wrapper.filename("Counter")
      {:ok, "Counter_wrapper.cpp"}

      iex> SvPortSim.Verilator.Wrapper.filename("../Counter")
      {:error, {:invalid_top_module, "../Counter"}}
  """
  @spec filename(term()) :: {:ok, String.t()} | {:error, term()}
  def filename(top_module) when is_binary(top_module) do
    with :ok <- validate_top_module(top_module) do
      {:ok, "#{top_module}_wrapper.cpp"}
    end
  end

  def filename(top_module) do
    {:error, {:invalid_top_module, top_module}}
  end

  @doc """
  Generates the C++ wrapper source for `top_module`.

  The generated source includes the Verilator-generated header
  `"V<top_module>.h"` and `verilated.h`. Its `main` function creates a
  `VerilatedContext`, passes command-line arguments to it, instantiates
  `V<top_module>`, calls `eval()` once, calls `final()`, releases the allocated
  objects, and returns `0`.

  Returns `{:ok, source}` on success.

  Returns `{:error, {:invalid_top_module, top_module}}` when `top_module` is
  not a binary or does not satisfy the accepted identifier format.

  ## Examples

      iex> {:ok, source} = SvPortSim.Verilator.Wrapper.source("Counter")
      iex> source =~ ~s(#include "VCounter.h")
      true
      iex> source =~ "top->eval();"
      true
      iex> source =~ "top->final();"
      true
  """
  @spec source(term()) :: {:ok, String.t()} | {:error, term()}
  def source(top_module) when is_binary(top_module) do
    with :ok <- validate_top_module(top_module) do
      {:ok, wrapper_source(top_module)}
    end
  end

  def source(top_module) do
    {:error, {:invalid_top_module, top_module}}
  end

  @doc """
  Writes the generated C++ wrapper source for `top_module` into `dir`.

  The output file is named with `filename/1` and placed directly under `dir`.
  The directory is created if it does not already exist. If the destination file
  already exists, it is overwritten.

  Returns `{:ok, path}` on success.

  Returns one of the following error tuples:

    * `{:error, {:invalid_arguments, top_module, dir}}` when either argument is
      not a binary
    * `{:error, {:invalid_top_module, top_module}}` when `top_module` is a
      binary but does not satisfy the accepted identifier format
    * `{:error, {:mkdir_failed, dir, reason}}` when creating `dir` fails
    * `{:error, {:write_failed, path, reason}}` when writing the wrapper source
      fails

  ## Example

      dir = Path.join(System.tmp_dir!(), "sv_port_sim_wrappers")
      {:ok, path} = SvPortSim.Verilator.Wrapper.write("Counter", dir)
  """
  @spec write(term(), term()) :: {:ok, Path.t()} | {:error, term()}
  def write(top_module, dir) when is_binary(top_module) and is_binary(dir) do
    with {:ok, filename} <- filename(top_module),
         {:ok, source} <- source(top_module),
         :ok <- mkdir_p(dir) do
      path = Path.join(dir, filename)

      case File.write(path, source) do
        :ok -> {:ok, path}
        {:error, reason} -> {:error, {:write_failed, path, reason}}
      end
    end
  end

  def write(top_module, dir) do
    {:error, {:invalid_arguments, top_module, dir}}
  end

  defp mkdir_p(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, dir, reason}}
    end
  end

  defp wrapper_source(top_module) do
    verilated_class = "V#{top_module}"

    """
    #include "#{verilated_class}.h"
    #include "verilated.h"

    int main(int argc, char** argv) {
        auto contextp = new VerilatedContext;
        contextp->commandArgs(argc, argv);

        auto top = new #{verilated_class}{contextp};

        top->eval();
        top->final();

        delete top;
        delete contextp;

        return 0;
    }
    """
  end

  defp validate_top_module(top_module) do
    if Regex.match?(@sv_identifier, top_module) do
      :ok
    else
      {:error, {:invalid_top_module, top_module}}
    end
  end
end
