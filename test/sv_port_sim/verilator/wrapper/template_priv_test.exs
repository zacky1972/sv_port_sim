defmodule SvPortSim.Verilator.Wrapper.TemplatePrivTest do
  use ExUnit.Case, async: true

  @template_path Path.expand("../../../../priv/sv_port_sim/wrapper.cpp.eex", __DIR__)
  @template_module_path Path.expand(
                          "../../../../lib/sv_port_sim/verilator/wrapper/template.ex",
                          __DIR__
                        )

  test "wrapper template is stored under priv as EEx" do
    source = File.read!(@template_path)

    assert source =~ "<%= verilated_class %>"
    assert source =~ "<%= top_module %>"
    assert source =~ "<%= signal_specs_json %>"
    assert source =~ "<%= poke_cases %>"
    assert source =~ "<%= peek_cases %>"

    refute String.contains?(source, old_placeholder("VERILATED_CLASS"))
    refute String.contains?(source, old_placeholder("TOP_MODULE"))
    refute String.contains?(source, old_placeholder("SIGNAL_SPECS_JSON"))
    refute String.contains?(source, old_placeholder("POKE_CASES"))
    refute String.contains?(source, old_placeholder("PEEK_CASES"))
  end

  test "Template module renders from an external resource" do
    source = File.read!(@template_module_path)

    assert source =~ "@external_resource"
    assert source =~ "EEx.function_from_file"
    refute source =~ "@wrapper_template"
  end

  defp old_placeholder(name), do: "@" <> "@" <> name <> "@" <> "@"
end
