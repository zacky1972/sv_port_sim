defmodule SvPortSim.Verilator.Wrapper.ValidatorTest do
  use ExUnit.Case, async: true

  alias SvPortSim.Verilator.Wrapper
  alias SvPortSim.Verilator.Wrapper.Validator

  describe "top_module/1" do
    test "accepts the safe SystemVerilog identifier subset used by Wrapper" do
      for top_module <- [
            "Counter",
            "counter",
            "_Counter",
            "Counter_1",
            "Counter$impl",
            "A$b$c",
            "_"
          ] do
        assert Validator.top_module(top_module) == :ok
        assert Validator.top_module?(top_module)
        assert Wrapper.filename(top_module) == {:ok, "#{top_module}_wrapper.cpp"}
      end
    end

    test "rejects unsupported top-module identifier shapes" do
      for top_module <- [
            "",
            "1Counter",
            "Counter-Top",
            "Counter.Top",
            "Counter/Top",
            "Counter Top",
            "\\Counter ",
            "日本語",
            "Counter\nTop"
          ] do
        assert Validator.top_module(top_module) == {:error, {:invalid_top_module, top_module}}
        refute Validator.top_module?(top_module)
        assert Wrapper.filename(top_module) == {:error, {:invalid_top_module, top_module}}
        assert Wrapper.source(top_module) == {:error, {:invalid_top_module, top_module}}
      end
    end

    test "rejects non-binary top-module values with the Wrapper error shape" do
      for top_module <- [nil, :Counter, ~c"Counter", 42, %{}, ["Counter"]] do
        assert Validator.top_module(top_module) == {:error, {:invalid_top_module, top_module}}
        refute Validator.top_module?(top_module)
        assert Wrapper.filename(top_module) == {:error, {:invalid_top_module, top_module}}
        assert Wrapper.source(top_module) == {:error, {:invalid_top_module, top_module}}
      end
    end
  end

  describe "Wrapper integration" do
    test "source/2 preserves top-module validation before signal-spec validation" do
      invalid_specs = [%{"this" => "would otherwise be invalid"}]

      assert Wrapper.source("1Counter", invalid_specs) ==
               {:error, {:invalid_top_module, "1Counter"}}
    end

    test "source/2 still delegates signal-spec validation after a valid top module" do
      invalid_specs = [%{"this" => "is not a valid signal spec"}]

      assert {:error, {:invalid_signal_specs, _reason}} =
               Wrapper.source("Counter", invalid_specs)
    end
  end
end
