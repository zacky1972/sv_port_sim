defmodule SvPortSim.Verilator.Wrapper do
  @moduledoc """
  Builds interactive C++ wrapper files for Verilated SystemVerilog top modules.

  The generated executable creates one `VerilatedContext` and one
  Verilator-generated top-module instance before entering the command loop. The
  same simulation session is reused for every protocol request until `stop`,
  `shutdown`, EOF, or a fatal wrapper/protocol failure terminates the process.

  `source/2` and `write/3` accept `SvPortSim.SignalSpec` metadata and generate
  C++ `poke_signal` and `peek_signal` dispatch functions for supported direct
  top-level Verilated fields. Unsupported or ambiguous shapes are represented by
  non-fatal `invalid_signal` paths instead of guessed field access.

  The `top_module` argument is the SystemVerilog top-module name without
  Verilator's `V` class-name prefix. For example, `"Counter"` maps to the
  Verilator-generated class `VCounter` and to the wrapper file
  `Counter_wrapper.cpp`.

  Accepted top-module names are limited to a safe identifier subset: the name
  must start with an ASCII letter or underscore, followed by ASCII letters,
  digits, underscores, or dollar signs.
  """

  alias SvPortSim.Verilator.Wrapper.Accessor
  alias SvPortSim.Verilator.Wrapper.Template

  @sv_identifier ~r/\A[A-Za-z_][A-Za-z0-9_$]*\z/
  @spec filename(term()) :: {:ok, String.t()} | {:error, term()}
  def filename(top_module) when is_binary(top_module) do
    with :ok <- validate_top_module(top_module) do
      {:ok, "#{top_module}_wrapper.cpp"}
    end
  end

  def filename(top_module), do: {:error, {:invalid_top_module, top_module}}

  @doc """
  Generates the interactive C++ wrapper source for `top_module` with no signal
  accessors.

  ## Examples

      iex> {:ok, source} = SvPortSim.Verilator.Wrapper.source("Counter")
      iex> source =~ ~s(#include "VCounter.h")
      true
      iex> source =~ "while (true)"
      true
      iex> source =~ ~s(op == "tick" || op == "cycle")
      true
  """
  @spec source(term()) :: {:ok, String.t()} | {:error, term()}
  def source(top_module) when is_binary(top_module), do: source(top_module, [])
  def source(top_module), do: {:error, {:invalid_top_module, top_module}}

  @doc """
  Generates the interactive C++ wrapper source for `top_module` with generated
  `poke` and `peek` accessors derived from `signal_specs`.

  ## Examples

      iex> specs = [SvPortSim.SignalSpec.data("enable", "input", "bit", 1)]
      iex> {:ok, source} = SvPortSim.Verilator.Wrapper.source("Counter", specs)
      iex> source =~ "AccessorResult poke_signal"
      true
      iex> source =~ "top->enable ="
      true
  """
  @spec source(term(), term()) :: {:ok, String.t()} | {:error, term()}
  def source(top_module, signal_specs) when is_binary(top_module) and is_list(signal_specs) do
    with :ok <- validate_top_module(top_module),
         {:ok, context} <- Accessor.context(signal_specs) do
      {:ok, wrapper_source(top_module, context)}
    end
  end

  def source(top_module, signal_specs) do
    {:error, {:invalid_arguments, top_module, signal_specs}}
  end

  @doc """
  Explicit alias for `source/1` that documents interactive wrapper generation.
  """
  @spec interactive_source(term()) :: {:ok, String.t()} | {:error, term()}
  def interactive_source(top_module), do: source(top_module)

  @doc """
  Explicit alias for `source/2` that documents interactive wrapper generation
  with generated signal accessors.
  """
  @spec interactive_source(term(), term()) :: {:ok, String.t()} | {:error, term()}
  def interactive_source(top_module, signal_specs), do: source(top_module, signal_specs)

  @doc """
  Writes the generated interactive C++ wrapper source for `top_module` into
  `dir`.
  """
  @spec write(term(), term()) :: {:ok, Path.t()} | {:error, term()}
  def write(top_module, dir) when is_binary(top_module) and is_binary(dir) do
    write_source(top_module, dir, fn -> source(top_module) end)
  end

  def write(top_module, dir), do: {:error, {:invalid_arguments, top_module, dir}}

  @doc """
  Writes the generated interactive C++ wrapper source for `top_module` into
  `dir`, including generated signal accessors derived from `signal_specs`.
  """
  @spec write(term(), term(), term()) :: {:ok, Path.t()} | {:error, term()}
  def write(top_module, dir, signal_specs)
      when is_binary(top_module) and is_binary(dir) and is_list(signal_specs) do
    write_source(top_module, dir, fn -> source(top_module, signal_specs) end)
  end

  def write(top_module, dir, signal_specs) do
    {:error, {:invalid_arguments, top_module, dir, signal_specs}}
  end

  defp write_source(top_module, dir, source_fun) do
    with {:ok, filename} <- filename(top_module),
         {:ok, source} <- source_fun.(),
         :ok <- mkdir_p(dir) do
      path = Path.join(dir, filename)

      case File.write(path, source) do
        :ok -> {:ok, path}
        {:error, reason} -> {:error, {:write_failed, path, reason}}
      end
    end
  end

  defp mkdir_p(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, dir, reason}}
    end
  end

  defp wrapper_source(top_module, context), do: Template.render(top_module, context)

  defp validate_top_module(top_module) do
    if Regex.match?(@sv_identifier, top_module) do
      :ok
    else
      {:error, {:invalid_top_module, top_module}}
    end
  end
end
