defmodule SvPortSim.Verilator.Wrapper.AccessorTest do
  use ExUnit.Case, async: true

  alias SvPortSim.SignalSpec
  alias SvPortSim.Verilator.Wrapper.Accessor

  doctest Accessor

  test "generates active-low reset dispatch" do
    specs = [
      SignalSpec.clock("clk"),
      SignalSpec.reset("rst_n", active: "low")
    ]

    assert {:ok, context} = Accessor.context(specs)

    assert context.reset_cases =~ ~s(reset == "rst_n")
    assert context.reset_cases =~ "const int active_level = 0;"
    assert context.reset_cases =~ "const int inactive_level = 1;"
    assert context.default_reset_case =~ ~s(reset = "rst_n";)
  end

  test "does not choose a default reset when multiple resets exist" do
    specs = [
      SignalSpec.clock("clk"),
      SignalSpec.reset("rst_n", active: "low"),
      SignalSpec.reset("rst", active: "high")
    ]

    assert {:ok, context} = Accessor.context(specs)
    assert context.default_reset_case =~ "return false;"
  end
end
