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

  test "source/1 no longer emits a one-shot eval/final main" do
    assert {:ok, source} = Wrapper.source("Counter")

    refute source =~ "top->eval();"
    refute source =~ "delete top;"
    refute source =~ "delete contextp;"
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

  test "source/1 emits canonical response and error envelope helpers" do
    assert {:ok, source} = Wrapper.source("Counter")

    assert source =~ "std::string response_envelope("
    assert source =~ "std::string error_body_json("
    assert source =~ "std::string error_envelope("
    assert source =~ "DispatchResult respond(const Request& request"
    assert source =~ "DispatchResult error_response("
    assert source =~ ~S(\"kind\":\"response\")
    assert source =~ ~S(\"kind\":\"error\")
    assert source =~ ~S(\"details\":)
    assert source =~ ~S(\"fatal\":)
  end

  test "source/1 uses structured success responses for successful commands" do
    assert {:ok, source} = Wrapper.source("Counter")

    assert source =~ "return respond(request, body);"
    assert source =~ ~s(op == "hello")
    assert source =~ ~s(op == "eval")
    assert source =~ ~s(op == "finish?")
    assert source =~ ~s(op == "stop" || op == "shutdown")
  end

  test "source/1 returns non-fatal structured errors for unsupported commands" do
    assert {:ok, source} = Wrapper.source("Counter")

    assert source =~ ~s("unsupported_command")
    assert source =~ ~s("unsupported command")
    assert source =~ "json_string_detail(\"operation\", op)"
    assert source =~ "false);"
  end

  test "source/1 validates invalid signal names and invalid encoded values without crashing" do
    assert {:ok, source} = Wrapper.source("Counter")

    assert source =~ "bool is_sv_identifier(const std::string& value)"
    assert source =~ "bool validate_signal_field("
    assert source =~ ~s("invalid_signal")
    assert source =~ "bool validate_encoded_value("
    assert source =~ ~s("invalid_value")
    assert source =~ "is_runtime_bit_string(bits)"
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
    assert source =~ "if (result.stop) {"
    assert source =~ "model.final();"
    assert source =~ "return result.exit_code;"
  end

  test "interactive_source/1 is an explicit alias for source/1" do
    assert Wrapper.interactive_source("Counter") == Wrapper.source("Counter")
  end

  describe "source/1 protocol helpers" do
    test "generates 4-byte big-endian frame readers and writers" do
      assert {:ok, source} = Wrapper.source("Counter")

      assert source =~ ~s(#include "VCounter.h")
      assert source =~ "constexpr std::uint32_t kMaxPayloadSize = 1024 * 1024;"
      assert source =~ "FrameRead read_frame()"
      assert source =~ "std::cin.read(reinterpret_cast<char*>(header), 4);"
      assert source =~ "static_cast<std::uint32_t>(header[0]) << 24"
      assert source =~ "length == 0"
      assert source =~ "length > kMaxPayloadSize"
      assert source =~ "std::string payload(length, '\\0');"
      assert source =~ "bool write_frame(const std::string& payload)"
      assert source =~ "std::cout.write(reinterpret_cast<const char*>(header), 4);"
      assert source =~ "std::cout.flush();"
    end

    test "generates strict JSON envelope parsing and response/error encoders" do
      assert {:ok, source} = Wrapper.source("Counter")

      assert source =~ "class JsonCursor"
      assert source =~ "bool parse_request(const std::string& payload"
      assert source =~ ~s(field == "v")
      assert source =~ ~s(field == "id")
      assert source =~ ~s(field == "kind")
      assert source =~ ~s(field == "op")
      assert source =~ ~s(field == "body")
      assert source =~ "trailing data after JSON envelope"
      assert source =~ "std::string response_envelope("
      assert source =~ "std::string error_envelope("
      assert source =~ ~S(\"kind\":\"response\")
      assert source =~ ~S(\"kind\":\"error\")
      assert source =~ "response_envelope(request.id, request.op, body_json)"

      assert source =~
               "error_envelope(request.id, request.op, code, message, details_json, fatal)"
    end

    test "main loop emits exactly one frame per decoded request before continuing or stopping" do
      assert {:ok, source} = Wrapper.source("Counter")

      assert occurrences(source, "write_frame(result.payload)") == 1
      assert source =~ "result = dispatcher.dispatch(request);"
      assert source =~ "if (result.stop)"
      assert source =~ "return result.exit_code;"
    end

    test "fatal protocol errors are framed and terminate without undefined behavior" do
      assert {:ok, source} = Wrapper.source("Counter")

      assert occurrences(source, "protocol_error_payload(request") >= 2
      assert source =~ "FrameRead::Fatal(\"empty payload\")"
      assert source =~ "FrameRead::Fatal(message.str())"
      assert source =~ "write_frame(protocol_error_payload(request, frame.message));"
      assert source =~ "write_frame(protocol_error_payload(request, parse_error));"
      assert source =~ "return 1;"
    end
  end

  defp occurrences(haystack, needle) do
    length(String.split(haystack, needle)) - 1
  end
end
