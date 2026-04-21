defmodule SvPortSim.Verilator.Wrapper do
  @moduledoc """
  Generates minimal C++ wrappers for Verilated SystemVerilog top modules.
  """

  @sv_identifier ~r/\A[A-Za-z_][A-Za-z0-9_$]*\z/

  @type top_module :: String.t()

  @doc """
  Returns the default C++ wrapper file name for a top module.
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
  Generates a minimal C++ wrapper source for a Verilated top module.

  The generated wrapper only instantiates the model, calls `eval/0` once,
  calls `final/0`, and exits. It is intended as a compile smoke wrapper.
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
  Writes a minimal C++ wrapper into `dir`.

  Returns the written file path.
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
