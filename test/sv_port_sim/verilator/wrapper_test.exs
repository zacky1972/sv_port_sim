defmodule SvPortSim.Verilator.WrapperTest do
  use ExUnit.Case, async: true

  alias SvPortSim.SignalSpec
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
    assert source =~ "top_->eval();"
    assert source =~ "top_->final();"
    assert source =~ "while (true)"
    assert source =~ ~s(op == "tick" || op == "cycle")
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

  test "source/1 advances VerilatedContext time through named clock ticks" do
    assert {:ok, source} = Wrapper.source("Counter", [SignalSpec.clock("clk")])

    assert source =~ "void tick_clock(SetClock set_clock, bool posedge)"
    assert source =~ "bool parse_clock(const Request& request"
    assert source =~ "const ClockResult tick = tick_clock(session_, clock);"
    refute source =~ "session_.advance_cycles(cycles);"

    assert source =~ ~S|body << "{\"clock\":" << json_quote(clock)|
    assert source =~ ~S|<< ",\"cycles\":" << cycles|
    assert source =~ ~S|<< ",\"time\":" << session_.time()|
    assert source =~ ~S|<< ",\"cycle\":" << session_.cycle()|
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
    assert source =~ ~S|const char* status = request.op == "shutdown" ? "closing" : "stopped";|
    assert source =~ ~S|body << "{\"status\":\"" << status|
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

  test "source/2 emits non-fatal validation errors for invalid clock and cycles" do
    assert {:ok, source} = Wrapper.source("Counter", [SignalSpec.clock("clk")])

    assert source =~ ~s|"invalid_signal"|
    assert source =~ ~s|"invalid clock"|
    assert source =~ "clock_detail(tick.clock)"
    assert source =~ ~s|"invalid_value"|
    assert source =~ ~s|"cycle count must be positive"|
    assert source =~ "false"
  end

  test "source/2 defaults omitted clock only when exactly one clock exists" do
    assert {:ok, one_clock_source} =
             Wrapper.source("Counter", [SignalSpec.clock("clk")])

    assert one_clock_source =~ ~s|clock = "clk";|
    assert one_clock_source =~ "return true;"

    assert {:ok, no_clock_source} = Wrapper.source("Counter", [])

    assert no_clock_source =~ "return false;"
  end

  test "source/2 generates clock dispatch for posedge and negedge clocks" do
    specs = [
      SignalSpec.clock("clk"),
      SignalSpec.clock("nclk", edge: "negedge")
    ]

    assert {:ok, source} = Wrapper.source("Counter", specs)

    assert source =~ ~s|if (clock == "clk")|
    assert source =~ "top->clk = static_cast<decltype(top->clk)>(value);"
    assert source =~ "session.tick_clock"
    assert source =~ ", true);"

    assert source =~ ~s|if (clock == "nclk")|
    assert source =~ "top->nclk = static_cast<decltype(top->nclk)>(value);"
    assert source =~ ", false);"

    assert source =~ ~s|return invalid_clock(clock, "unknown clock");|
  end

  test "source/2 generates poke and peek dispatch from signal specs" do
    specs = [
      SignalSpec.data("enable", "input", "bit", 1),
      SignalSpec.data("count", "output", "logic", 8),
      SignalSpec.data("bus", "inout", "logic", 4)
    ]

    assert {:ok, source} = Wrapper.source("Counter", specs)

    assert source =~ "AccessorResult poke_signal(SimulationSession& session"

    assert source =~ ~s|if (signal == "enable")|

    assert source =~
             "top->enable = static_cast<decltype(top->enable)>(bits_to_uint64(value.bits));"

    assert source =~ ~s|return invalid_signal_accessor(signal, "signal is not readable");|

    assert source =~ ~s|if (signal == "count")|
    assert source =~ ~s|return invalid_signal_accessor(signal, "signal is not writable");|

    assert source =~
             "return ok_accessor(encode_signal(static_cast<std::uint64_t>(top->count), 8));"

    assert source =~
             "top->bus = static_cast<decltype(top->bus)>(bits_to_uint64(value.bits));"

    assert source =~
             "return ok_accessor(encode_signal(static_cast<std::uint64_t>(top->bus), 4));"
  end

  test "source/2 emits non-fatal invalid_signal and invalid_value result paths" do
    specs = [SignalSpec.data("enable", "input", "bit", 1)]

    assert {:ok, source} = Wrapper.source("Counter", specs)

    assert source =~ ~s(result.code = "invalid_signal";)
    assert source =~ ~s(result.code = "invalid_value";)
    assert source =~ ~s|return invalid_signal_accessor(signal, "unknown signal");|
    assert source =~ ~s|return invalid_value_accessor(signal, "invalid encoded value");|
    assert source =~ "valid_two_state_encoded_value(value, 1)"
    assert source =~ "signal_detail(result.signal), false);"
  end

  test "source/2 maps unsupported native accessor widths to safe invalid_signal cases" do
    specs = [SignalSpec.data("wide", "input", "logic", 65)]

    assert {:ok, source} = Wrapper.source("Counter", specs)

    assert source =~ ~s|if (signal == "wide")|
    assert source =~ "signal shape is not supported by generated accessors"
    refute source =~ "top->wide ="
  end

  test "source/2 embeds normalized signal metadata for metadata command" do
    specs = [SignalSpec.data("count", "output", "logic", 8)]

    assert {:ok, source} = Wrapper.source("Counter", specs)

    assert source =~ ~s(const char* kSignalSpecsJson = R"svps_json()
    assert source =~ ~s("name":"count")
    assert source =~ ~s("direction":"output")
    assert source =~ ~s("width":8)
  end

  test "source/2 rejects invalid signal spec lists" do
    specs = [
      SignalSpec.data("enable", "input", "bit", 1),
      SignalSpec.data("enable", "output", "logic", 1)
    ]

    assert Wrapper.source("Counter", specs) ==
             {:error, {:invalid_signal_specs, {:duplicate_signal_names, ["enable"]}}}
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

  test "write/3 writes accessor-enabled wrapper source to directory" do
    dir =
      Path.join([
        System.tmp_dir!(),
        "sv_port_sim_wrapper_test_#{System.unique_integer([:positive])}"
      ])

    specs = [SignalSpec.data("enable", "input", "bit", 1)]

    on_exit(fn -> File.rm_rf(dir) end)

    assert {:ok, path} = Wrapper.write("Counter", dir, specs)

    assert path == Path.join(dir, "Counter_wrapper.cpp")
    assert File.exists?(path)
    assert File.read!(path) =~ "top->enable ="
  end

  test "source/2 preserves generated poke dispatch semantics" do
    assert {:ok, source} = Wrapper.source("Counter", accessor_fixture_specs())

    assert generated_cpp_function(source, "poke_signal", "AccessorResult peek_signal") ==
             normalize_cpp(~S"""
             AccessorResult poke_signal(SimulationSession& session, const std::string& signal, const EncodedValue& value) {
               if (signal == "enable") {
                 if (!valid_two_state_encoded_value(value, 1)) {
                   return invalid_value_accessor(signal, "invalid encoded value");
                 }
                 auto top = session.top_model();
                 top->enable = static_cast<decltype(top->enable)>(bits_to_uint64(value.bits));
                 session.eval();
                 return ok_accessor(encode_signal(static_cast<std::uint64_t>(top->enable), 1));
               }

               if (signal == "count") {
                 return invalid_signal_accessor(signal, "signal is not writable");
               }

               if (signal == "bus") {
                 if (!valid_two_state_encoded_value(value, 4)) {
                   return invalid_value_accessor(signal, "invalid encoded value");
                 }
                 auto top = session.top_model();
                 top->bus = static_cast<decltype(top->bus)>(bits_to_uint64(value.bits));
                 session.eval();
                 return ok_accessor(encode_signal(static_cast<std::uint64_t>(top->bus), 4));
               }

               if (signal == "wide") {
                 return invalid_signal_accessor(signal, "signal shape is not supported by generated accessors");
               }

               return invalid_signal_accessor(signal, "unknown signal");
             }
             """)
  end

  test "source/2 preserves generated peek dispatch semantics" do
    assert {:ok, source} = Wrapper.source("Counter", accessor_fixture_specs())

    assert generated_cpp_function(source, "peek_signal", "int finish_session") ==
             normalize_cpp(~S"""
             AccessorResult peek_signal(SimulationSession& session, const std::string& signal) {
               if (signal == "enable") {
                 return invalid_signal_accessor(signal, "signal is not readable");
               }

               if (signal == "count") {
                 auto top = session.top_model();
                 return ok_accessor(encode_signal(static_cast<std::uint64_t>(top->count), 8));
               }

               if (signal == "bus") {
                 auto top = session.top_model();
                 return ok_accessor(encode_signal(static_cast<std::uint64_t>(top->bus), 4));
               }

               if (signal == "wide") {
                 return invalid_signal_accessor(signal, "signal shape is not supported by generated accessors");
               }

               return invalid_signal_accessor(signal, "unknown signal");
             }
             """)
  end

  test "source/2 embeds deterministic full signal metadata JSON" do
    assert {:ok, source} = Wrapper.source("Counter", accessor_fixture_specs())

    assert embedded_signal_specs_json(source) ==
             ~S([{"direction":"input","name":"enable","packed":{"dimensions":[],"kind":"scalar"},"role":{"kind":"data"},"signed":false,"type":"bit","width":1},{"direction":"output","name":"count","packed":{"dimensions":[{"left":7,"right":0}],"kind":"packed_vector"},"role":{"kind":"data"},"signed":false,"type":"logic","width":8},{"direction":"inout","name":"bus","packed":{"dimensions":[{"left":3,"right":0}],"kind":"packed_vector"},"role":{"kind":"data"},"signed":false,"type":"logic","width":4},{"direction":"input","name":"wide","packed":{"dimensions":[{"left":64,"right":0}],"kind":"packed_vector"},"role":{"kind":"data"},"signed":false,"type":"logic","width":65}])
  end

  test "source/2 treats SystemVerilog-only identifiers as unsupported native accessor fields" do
    specs = [SignalSpec.data("debug$value", "inout", "logic", 1)]

    assert {:ok, source} = Wrapper.source("Counter", specs)

    assert source =~ ~s|if (signal == "debug$value")|
    assert source =~ "signal shape is not supported by generated accessors"
    assert embedded_signal_specs_json(source) =~ ~S("name":"debug$value")

    refute source =~ "top->debug$value"
  end

  test "tracing is disabled by default" do
    assert {:ok, source} = Wrapper.source("Counter")

    refute source =~ "verilated_vcd_c.h"
    refute source =~ "verilated_fst_c.h"
    refute source =~ "traceEverOn"
    refute source =~ "tracep_"
    refute source =~ ".vcd"
    refute source =~ ".fst"
  end

  test "VCD tracing hooks can be generated" do
    assert {:ok, source} = Wrapper.source("Counter", [], trace: :vcd)

    assert source =~ ~s(#include "verilated_vcd_c.h")
    assert source =~ "VerilatedVcdC"
    assert source =~ "+svps_trace"
    assert source =~ "+svps_trace_file="
    assert source =~ "trace.vcd"
    assert source =~ "traceEverOn(true)"
    assert source =~ "top_->trace(tracep_.get(), 99)"
    assert source =~ "tracep_->open"
    assert source =~ "tracep_->dump(contextp_->time())"
    assert source =~ "tracep_->close()"
  end

  test "FST tracing hooks can be generated" do
    assert {:ok, source} = Wrapper.source("Counter", [], trace: :fst)

    assert source =~ ~s(#include "verilated_fst_c.h")
    assert source =~ "VerilatedFstC"
    assert source =~ "trace.fst"
    assert source =~ "tracep_->dump(contextp_->time())"
    assert source =~ "tracep_->close()"
  end

  test "unsupported trace mode returns structured error" do
    assert {:error, {:unsupported_trace_mode, :saif}} =
             Wrapper.source("Counter", [], trace: :saif)
  end

  defp accessor_fixture_specs do
    [
      SignalSpec.data("enable", "input", "bit", 1),
      SignalSpec.data("count", "output", "logic", 8),
      SignalSpec.data("bus", "inout", "logic", 4),
      SignalSpec.data("wide", "input", "logic", 65)
    ]
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

  defp occurrences(haystack, needle) do
    length(String.split(haystack, needle)) - 1
  end
end
