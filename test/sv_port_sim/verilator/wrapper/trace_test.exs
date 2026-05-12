defmodule SvPortSim.Verilator.Wrapper.TraceTest do
  use ExUnit.Case, async: true

  alias SvPortSim.Verilator.Wrapper.Trace

  doctest Trace

  test "trace modes map to Verilator args" do
    assert {:ok, []} = Trace.verilator_args(false)
    assert {:ok, ["--trace-vcd"]} = Trace.verilator_args(:vcd)
    assert {:ok, ["--trace-fst"]} = Trace.verilator_args(:fst)

    assert {:error, {:unsupported_trace_mode, :saif}} =
             Trace.verilator_args(:saif)
  end
end
