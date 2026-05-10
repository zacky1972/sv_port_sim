defmodule SvPortSim.RtlTest do
  use ExUnit.Case, async: false

  alias SvPortSim.Rtl

  doctest Rtl

  test "source_filename/1 builds .sv filename from module name" do
    assert Rtl.source_filename("Counter") == {:ok, "Counter.sv"}
  end

  test "source_filename/1 rejects unsafe module names" do
    assert Rtl.source_filename("../Counter") ==
             {:error, {:invalid_module_name, "../Counter"}}
  end

  test "expand/2 writes SystemVerilog sources into the rtl directory" do
    sources = %{
      "Counter" => "module Counter; endmodule",
      "Helper" => "module Helper; endmodule"
    }

    assert {:ok, result} = Rtl.expand("Counter", sources)

    assert result.top_module == "Counter"
    assert File.exists?(result.files["Counter"])
    assert File.exists?(result.files["Helper"])
    assert File.read!(result.files["Counter"]) == "module Counter; endmodule"
    assert File.read!(result.files["Helper"]) == "module Helper; endmodule"
  end

  test "expand/2 rejects missing top module" do
    sources = %{
      "Helper" => "module Helper; endmodule"
    }

    assert Rtl.expand("Counter", sources) ==
             {:error, {:top_module_not_found, "Counter"}}
  end
end
