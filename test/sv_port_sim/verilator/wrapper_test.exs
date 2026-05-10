defmodule SvPortSim.Verilator.WrapperTest do
  use ExUnit.Case, async: true

  alias SvPortSim.Verilator.Wrapper

  doctest Wrapper

  test "filename/1 returns default wrapper filename" do
    assert Wrapper.filename("Counter") == {:ok, "Counter_wrapper.cpp"}
  end

  test "filename/1 rejects unsafe top module names" do
    assert Wrapper.filename("../Counter") == {:error, {:invalid_top_module, "../Counter"}}
  end

  test "source/1 generates minimal C++ wrapper for top module" do
    assert {:ok, source} = Wrapper.source("Counter")

    assert source =~ ~s(#include "VCounter.h")
    assert source =~ ~s(#include "verilated.h")
    assert source =~ "new VCounter{contextp}"
    assert source =~ "top->eval();"
    assert source =~ "top->final();"
  end

  test "source/1 rejects invalid top module" do
    assert Wrapper.source("Counter/Bad") == {:error, {:invalid_top_module, "Counter/Bad"}}
  end

  test "write/2 writes wrapper source to directory" do
    dir =
      Path.join([
        System.tmp_dir!(),
        "sv_port_sim_wrapper_test_#{System.unique_integer([:positive])}"
      ])

    on_exit(fn -> File.rm_rf(dir) end)

    assert {:ok, path} = Wrapper.write("Counter", dir)

    assert path == Path.join(dir, "Counter_wrapper.cpp")
    assert File.exists?(path)
    assert File.read!(path) =~ ~s(#include "VCounter.h")
  end
end
