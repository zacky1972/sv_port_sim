defmodule SvPortSim.Verilator.Wrapper.Template do
  @moduledoc """
  Renders the interactive C++ wrapper template for Verilated top modules.

  The C++ runtime skeleton lives in `priv/sv_port_sim/wrapper.cpp.eex`.
  Accessor-specific fragments are expected to be supplied by
  `SvPortSim.Verilator.Wrapper.Accessor.context/1`.
  """

  alias SvPortSim.Verilator.Wrapper.JsonLiteral

  require EEx

  @type context :: %{
          required(:signal_specs_json) => String.t(),
          required(:poke_cases) => String.t(),
          required(:peek_cases) => String.t(),
          optional(atom()) => term()
        }

  @template_path Path.expand("../../../../priv/sv_port_sim/wrapper.cpp.eex", __DIR__)
  @external_resource @template_path

  EEx.function_from_file(
    :defp,
    :render_template,
    @template_path,
    [:verilated_class, :top_module, :signal_specs_json, :poke_cases, :peek_cases],
    trim: false
  )

  @doc """
  Renders wrapper C++ source for `top_module` using prebuilt accessor context.
  """
  @spec render(String.t(), context()) :: String.t()
  def render(top_module, %{
        signal_specs_json: signal_specs_json,
        poke_cases: poke_cases,
        peek_cases: peek_cases
      })
      when is_binary(top_module) and is_binary(signal_specs_json) and is_binary(poke_cases) and
             is_binary(peek_cases) do
    render_template(
      "V#{top_module}",
      JsonLiteral.cpp_string(top_module),
      signal_specs_json,
      poke_cases,
      peek_cases
    )
  end
end
