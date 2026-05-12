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
    assert source =~ "std::unique_ptr<VerilatedContext> contextp_"
    assert source =~ "std::unique_ptr<VCounter> top_"
    assert source =~ "new VCounter{contextp_.get()}"
    assert source =~ "while (true)"
    assert source =~ "read_frame()"
    assert source =~ "write_frame(result.payload)"
  end

  test "source/1 owns one persistent simulation session outside the command loop" do
    assert {:ok, source} = Wrapper.source("Counter")

    assert source =~ "class SimulationSession"
    assert source =~ "SimulationSession session(argc, argv);"
    assert source =~ "CommandDispatcher dispatcher(session);"
    assert source =~ "explicit CommandDispatcher(SimulationSession& session)"
    assert occurrences(source, "new VerilatedContext") == 1
    assert occurrences(source, "new VCounter{contextp_.get()}") == 1
  end

  test "source/1 advances shared VerilatedContext time for tick and cycle" do
    assert {:ok, source} = Wrapper.source("Counter")

    assert source =~ ~s(op == "tick" || op == "cycle")
    assert source =~ "void advance_cycles(std::uint64_t cycles)"
    assert source =~ "contextp_->timeInc(1);"
    assert source =~ "session_.advance_cycles(cycles);"
    assert source =~ ~S(\"time\":)
    assert source =~ ~S(\"cycles\":)
  end

  test "source/1 finalizes through one guarded terminal cleanup path" do
    assert {:ok, source} = Wrapper.source("Counter")

    assert source =~ "void final()"
    assert source =~ "if (!finalized_)"
    assert occurrences(source, "top_->final();") == 1
    assert source =~ "int finish_session(SimulationSession& session, int exit_code)"
    assert source =~ "return finish_session(session, 0);"
    assert source =~ "return finish_session(session, 1);"
    assert source =~ "return finish_session(session, result.exit_code);"
    refute source =~ "delete top;"
    refute source =~ "delete contextp;"
  end

  test "source/1 handles stop and shutdown as terminal commands" do
    assert {:ok, source} = Wrapper.source("Counter")

    assert source =~ ~s(op == "stop" || op == "shutdown")
    assert source =~ "result.stop = true;"
    assert source =~ "result.exit_code = 0;"
    assert source =~ ~S(\"status\":\"stopped\")
  end

  test "source/1 includes EOF, fatal protocol, and malformed-request cleanup paths" do
    assert {:ok, source} = Wrapper.source("Counter")

    assert source =~ "FrameRead::eof"
    assert source =~ "FrameRead::fatal"
    assert source =~ ~s("protocol_error")
    assert source =~ "protocol_error_payload(request, frame.message)"
    assert source =~ "protocol_error_payload(request, parse_error)"
  end

  test "source/1 no longer emits a one-shot eval/final main" do
    assert {:ok, source} = Wrapper.source("Counter")

    refute source =~ "top->eval();"
    refute source =~ "top->final();"
    refute source =~ "new VCounter{contextp}"
  end

  test "source/1 generates 4-byte big-endian frame readers and writers" do
    assert {:ok, source} = Wrapper.source("Counter")

    assert source =~ "constexpr std::uint32_t kMaxPayloadSize = 1024 * 1024;"
    assert source =~ "std::cin.read(reinterpret_cast<char*>(header), 4);"
    assert source =~ "static_cast<std::uint32_t>(header[0]) << 24"
    assert source =~ "std::cout.write(reinterpret_cast<const char*>(header), 4);"
    assert source =~ "std::cout.flush();"
  end

  test "source/1 generates strict request parsing and response/error envelopes" do
    assert {:ok, source} = Wrapper.source("Counter")

    assert source =~ "bool parse_request(const std::string& payload, Request& request"
    assert source =~ "request.has_id = true;"
    assert source =~ "request.has_op = true;"
    assert source =~ ~S(\"kind\":\"response\")
    assert source =~ ~S(\"kind\":\"error\")
    assert source =~ ~S(\"fatal\":)
  end

  test "source/1 rejects invalid top module" do
    assert Wrapper.source("Counter/Bad") == {:error, {:invalid_top_module, "Counter/Bad"}}
  end

  test "interactive_source/1 is an explicit alias for source/1" do
    assert Wrapper.interactive_source("Counter") == Wrapper.source("Counter")
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
    assert source =~ "SimulationSession"
    assert source =~ "while (true)"
  end

  defp occurrences(haystack, needle) do
    length(String.split(haystack, needle)) - 1
  end
end
