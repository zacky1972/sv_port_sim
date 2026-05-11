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

  test "source/1 generates interactive C++ wrapper for top module" do
    assert {:ok, source} = Wrapper.source("Counter")

    assert source =~ ~s(#include "VCounter.h")
    assert source =~ ~s(#include "verilated.h")
    assert source =~ "std::unique_ptr<VCounter>"
    assert source =~ "new VCounter{contextp.get()}"
    assert source =~ "while (true)"
    assert source =~ "read_frame()"
    assert source =~ "write_frame(result.payload)"
  end

  test "source/1 keeps command dispatch separate from model-specific accessors" do
    assert {:ok, source} = Wrapper.source("Counter")

    assert source =~ "class ModelAccessors"
    assert source =~ "class CommandDispatcher"
    assert source =~ "DispatchResult dispatch(const Request& request)"
    assert source =~ "ModelAccessors& model_"
  end

  test "source/1 handles stop and shutdown as graceful terminal commands" do
    assert {:ok, source} = Wrapper.source("Counter")

    assert source =~ ~s(op == "stop" || op == "shutdown")
    assert source =~ "model_.final();"
    assert source =~ "result.exit_code = 0;"
  end

  test "source/1 includes fatal protocol cleanup path and EOF path" do
    assert {:ok, source} = Wrapper.source("Counter")

    assert source =~ "FrameRead::eof"
    assert source =~ "FrameRead::fatal"
    assert source =~ ~s("protocol_error")
    assert source =~ "~ModelAccessors() { final(); }"
  end

  test "source/1 no longer emits a one-shot eval/final main" do
    assert {:ok, source} = Wrapper.source("Counter")

    refute source =~ "top->eval();"
    refute source =~ "delete top;"
    refute source =~ "delete contextp;"
  end

  test "interactive_source/1 is an explicit alias for source/1" do
    assert Wrapper.interactive_source("Counter") == Wrapper.source("Counter")
  end

  test "source/1 rejects invalid top module" do
    assert Wrapper.source("Counter/Bad") == {:error, {:invalid_top_module, "Counter/Bad"}}
  end

  test "write/2 writes interactive wrapper source to directory" do
    dir =
      Path.join([
        System.tmp_dir!(),
        "sv_port_sim_wrapper_test_#{System.unique_integer([:positive])}"
      ])

    on_exit(fn -> File.rm_rf(dir) end)

    assert {:ok, path} = Wrapper.write("Counter", dir)

    assert path == Path.join(dir, "Counter_wrapper.cpp")
    assert File.exists?(path)

    source = File.read!(path)
    assert source =~ ~s(#include "VCounter.h")
    assert source =~ "while (true)"
  end
end
