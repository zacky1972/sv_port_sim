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
          optional(:clock_cases) => String.t(),
          optional(:default_clock_case) => String.t(),
          optional(:reset_cases) => String.t(),
          optional(:default_reset_case) => String.t(),
          optional(atom()) => term()
        }

  @template_path Path.expand("../../../../priv/sv_port_sim/wrapper.cpp.eex", __DIR__)

  @external_resource @template_path

  EEx.function_from_file(
    :defp,
    :render_template,
    @template_path,
    [
      :verilated_class,
      :top_module,
      :signal_specs_json,
      :poke_cases,
      :peek_cases,
      :clock_cases,
      :default_clock_case,
      :reset_cases,
      :default_reset_case,
      :trace_include,
      :trace_helpers,
      :trace_ctor_init,
      :trace_ctor_body,
      :trace_members,
      :trace_dump_call,
      :trace_close_call
    ],
    trim: false
  )

  @doc """
  Renders wrapper C++ source for `top_module` using prebuilt accessor context.
  """
  @spec render(String.t(), context()) :: String.t()
  def render(
        top_module,
        %{
          signal_specs_json: signal_specs_json,
          poke_cases: poke_cases,
          peek_cases: peek_cases
        } = context
      )
      when is_binary(top_module) and is_binary(signal_specs_json) and is_binary(poke_cases) and
             is_binary(peek_cases) do
    clock_cases = Map.get(context, :clock_cases, "")
    default_clock_case = Map.get(context, :default_clock_case, "return false;\n")
    reset_cases = Map.get(context, :reset_cases, "")
    default_reset_case = Map.get(context, :default_reset_case, "return false;\n")

    trace =
      Map.get(context, :trace, %{
        include: "",
        helpers: "",
        ctor_init: "",
        ctor_body: "",
        members: "",
        dump_call: "",
        close_call: ""
      })

    render_template(
      "V#{top_module}",
      JsonLiteral.cpp_string(top_module),
      signal_specs_json,
      poke_cases,
      peek_cases,
      clock_cases,
      default_clock_case,
      reset_cases,
      default_reset_case,
      trace.include,
      trace.helpers,
      trace.ctor_init,
      trace.ctor_body,
      trace.members,
      trace.dump_call,
      trace.close_call
    )
    |> remove_duplicate_clock_detail()
    |> repair_reset_response_helpers()
  end

  defp remove_duplicate_clock_detail(source) do
    Regex.replace(
      ~r/\nstd::string clock_detail\(const std::string& clock\)\s*\{\s*if \(clock\.empty\(\)\)\s*\{\s*return "\{\}";\s*\}\s*return json_detail\("clock", clock\);\s*\}\s*(?=std::string signal_detail)/,
      source,
      "\n"
    )
  end

  defp repair_reset_response_helpers(source) do
    source
    |> String.replace("json_string(", "json_quote(")
    |> String.replace(
      "return response(request, body.str());",
      "return respond(request, body.str());"
    )
  end
end
