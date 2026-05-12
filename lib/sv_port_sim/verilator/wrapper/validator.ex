defmodule SvPortSim.Verilator.Wrapper.Validator do
  @moduledoc """
  Validates public inputs for generated Verilator wrapper source construction.

  This module owns the safe SystemVerilog top-module identifier subset used by
  `SvPortSim.Verilator.Wrapper`. The accepted subset is intentionally narrow:
  an ASCII letter or underscore followed by ASCII letters, digits, underscores,
  or dollar signs.
  """

  @sv_identifier ~r/\A[A-Za-z_][A-Za-z0-9_$]*\z/

  @doc """
  Validates a top-module name for wrapper generation.
  """
  @spec top_module(term()) :: :ok | {:error, {:invalid_top_module, term()}}
  def top_module(top_module) when is_binary(top_module) do
    if top_module?(top_module) do
      :ok
    else
      {:error, {:invalid_top_module, top_module}}
    end
  end

  def top_module(top_module), do: {:error, {:invalid_top_module, top_module}}

  @doc """
  Returns whether `top_module` is accepted by the wrapper generator.
  """
  @spec top_module?(term()) :: boolean()
  def top_module?(top_module) when is_binary(top_module),
    do: Regex.match?(@sv_identifier, top_module)

  def top_module?(_top_module), do: false
end
