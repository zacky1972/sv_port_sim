defmodule SvPortSim.Verilator.Wrapper.TemplateTest do
  use ExUnit.Case, async: true

  alias SvPortSim.SignalSpec
  alias SvPortSim.Verilator.Wrapper
  alias SvPortSim.Verilator.Wrapper.Accessor
  alias SvPortSim.Verilator.Wrapper.Template

  test "clock-aware template context is generated and rendered for tick and cycle" do
    specs = [
      SignalSpec.clock("clk"),
      SignalSpec.clock("clk_n", edge: "negedge")
    ]

    assert {:ok, generated_context} = Accessor.context(specs)
    assert Map.has_key?(generated_context, :clock_cases)
    assert Map.has_key?(generated_context, :default_clock_case)
    assert generated_context.clock_cases =~ ~s(clock == "clk")
    assert generated_context.clock_cases =~ ~s(clock == "clk_n")

    template_context = %{
      signal_specs_json: "[]",
      poke_cases: "",
      peek_cases: "",
      clock_cases: ~S(// fixture clock dispatch),
      default_clock_case: ~S(// fixture default clock dispatch)
    }

    source = Template.render("Counter", template_context)

    assert source =~ "// fixture clock dispatch"
    assert source =~ "// fixture default clock dispatch"
    refute source =~ "@@CLOCK_CASES@@"
    refute source =~ "@@DEFAULT_CLOCK_CASE@@"
  end

  describe "render/2" do
    test "matches Wrapper.source/1 for an empty accessor context" do
      assert {:ok, context} = Accessor.context([])
      assert {:ok, wrapper_source} = Wrapper.source("Counter")

      assert Template.render("Counter", context) == wrapper_source
    end

    test "matches Wrapper.source/2 for an accessor-enabled context" do
      specs = accessor_fixture_specs()

      assert {:ok, context} = Accessor.context(specs)
      assert {:ok, wrapper_source} = Wrapper.source("Counter", specs)

      assert Template.render("Counter", context) == wrapper_source
    end

    test "renders the interactive wrapper runtime skeleton for a top module" do
      source = Template.render("Counter", empty_context())

      assert source =~ ~s(#include "VCounter.h")
      assert source =~ ~s(#include "verilated.h")
      assert source =~ ~s(const char* kTopModule = "Counter";)
      assert source =~ "constexpr std::uint32_t kProtocolVersion = 1;"
      assert source =~ "class JsonCursor"
      assert source =~ "class SimulationSession"
      assert source =~ "std::unique_ptr<VCounter> top_;"
      assert source =~ "top_.reset(new VCounter{contextp_.get()});"
      assert source =~ "class CommandDispatcher"
      assert source =~ "while (true)"
      assert source =~ "read_frame()"
      assert source =~ "write_frame(result.payload)"
      assert source =~ ~s(op == "tick" || op == "cycle")
      assert source =~ ~s(op == "reset")
    end

    test "replaces every template placeholder" do
      source = Template.render("Counter", context_fixture())

      for placeholder <- [
            "@@VERILATED_CLASS@@",
            "@@TOP_MODULE@@",
            "@@SIGNAL_SPECS_JSON@@",
            "@@POKE_CASES@@",
            "@@PEEK_CASES@@"
          ] do
        refute source =~ placeholder
      end
    end

    test "embeds signal metadata JSON exactly in the raw-string literal" do
      metadata_json =
        ~S([{"direction":"input","name":"enable","packed":{"dimensions":[],"kind":"scalar"},"role":{"kind":"data"},"signed":false,"type":"bit","width":1}])

      source = Template.render("Counter", %{empty_context() | signal_specs_json: metadata_json})

      assert embedded_signal_specs_json(source) == metadata_json
      assert source =~ ~s|const char* kSignalSpecsJson = R"svps_json(#{metadata_json})svps_json";|
    end

    test "keeps empty accessor fragments as fallback-only dispatch functions" do
      source = Template.render("Counter", empty_context())

      assert generated_cpp_function(source, "poke_signal", "AccessorResult peek_signal") ==
               normalize_cpp(~S"""
               AccessorResult poke_signal(SimulationSession& session, const std::string& signal, const EncodedValue& value) {
                 return invalid_signal_accessor(signal, "unknown signal");
               }
               """)

      assert generated_cpp_function(source, "peek_signal", "int finish_session") ==
               normalize_cpp(~S"""
               AccessorResult peek_signal(SimulationSession& session, const std::string& signal) {
                 return invalid_signal_accessor(signal, "unknown signal");
               }
               """)
    end

    test "inserts generated poke and peek fragments into their dispatch functions only" do
      source = Template.render("Counter", context_fixture())

      poke_function = generated_cpp_function(source, "poke_signal", "AccessorResult peek_signal")
      peek_function = generated_cpp_function(source, "peek_signal", "int finish_session")

      assert poke_function ==
               normalize_cpp(~S"""
               AccessorResult poke_signal(SimulationSession& session, const std::string& signal, const EncodedValue& value) {
                 if (signal == "enable") {
                   return invalid_value_accessor(signal, "fixture poke case");
                 }
                 return invalid_signal_accessor(signal, "unknown signal");
               }
               """)

      assert peek_function ==
               normalize_cpp(~S"""
               AccessorResult peek_signal(SimulationSession& session, const std::string& signal) {
                 if (signal == "enable") {
                   return invalid_signal_accessor(signal, "fixture peek case");
                 }
                 return invalid_signal_accessor(signal, "unknown signal");
               }
               """)

      refute poke_function =~ "fixture peek case"
      refute peek_function =~ "fixture poke case"
    end
  end

  defp accessor_fixture_specs do
    [
      SignalSpec.data("enable", "input", "bit", 1),
      SignalSpec.data("count", "output", "logic", 8),
      SignalSpec.data("bus", "inout", "logic", 4),
      SignalSpec.data("wide", "input", "logic", 65)
    ]
  end

  defp empty_context do
    %{
      signal_specs_json: "[]",
      poke_cases: "",
      peek_cases: ""
    }
  end

  defp context_fixture do
    %{
      signal_specs_json:
        ~S([{"direction":"input","name":"enable","packed":{"dimensions":[],"kind":"scalar"},"role":{"kind":"data"},"signed":false,"type":"bit","width":1}]),
      poke_cases: ~S"""
      if (signal == "enable") {
        return invalid_value_accessor(signal, "fixture poke case");
      }
      """,
      peek_cases: ~S"""
      if (signal == "enable") {
        return invalid_signal_accessor(signal, "fixture peek case");
      }
      """
    }
  end

  defp generated_cpp_function(source, function_name, next_marker) do
    marker = "AccessorResult #{function_name}"
    [_, tail] = String.split(source, marker, parts: 2)
    [function_source, _] = String.split(tail, next_marker, parts: 2)

    normalize_cpp(marker <> function_source)
  end

  defp embedded_signal_specs_json(source) do
    prefix = ~s|const char* kSignalSpecsJson = R"svps_json(|
    suffix = ~s|)svps_json";|
    [_, tail] = String.split(source, prefix, parts: 2)
    [json, _] = String.split(tail, suffix, parts: 2)

    json
  end

  defp normalize_cpp(source) do
    source
    |> String.replace(~r/\s+/, " ")
    |> String.replace(~r/\s*([{}();,])\s*/, "\\1")
    |> String.replace(~r/\s*(==|=|->|::|<|>)\s*/, "\\1")
    |> String.trim()
  end
end
