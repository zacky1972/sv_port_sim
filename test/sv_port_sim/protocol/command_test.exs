defmodule SvPortSim.Protocol.CommandTest do
  use ExUnit.Case, async: true

  doctest SvPortSim.Protocol.Command

  alias SvPortSim.Protocol.Command

  @encoded_one %{"bits" => "1", "width" => 1}
  @encoded_count %{"bits" => "0010", "width" => 4}

  test "eval, cycle, and finish? have command and successful response schemas" do
    expected_commands = [
      "metadata",
      "reset",
      "eval",
      "poke",
      "tick",
      "cycle",
      "peek",
      "finish?",
      "shutdown"
    ]

    assert Command.command_names() == expected_commands
    assert Enum.map(Command.command_specs(), & &1.name) == expected_commands

    cases = [
      {"eval", %{}, %{"time" => 0, "cycle" => 0}},
      {"cycle", %{"clock" => "clk", "cycles" => 5},
       %{"clock" => "clk", "cycles" => 5, "time" => 10, "cycle" => 5}},
      {"finish?", %{}, %{"finished" => false, "time" => 10, "cycle" => 5}}
    ]

    for {{op, request_body, response_body}, id} <- Enum.with_index(cases, 1) do
      assert {:ok, request} = Command.request(op, id, request_body)
      assert Command.validate_request(request) == :ok

      assert {:ok, response} = Command.ok_response(request, response_body)
      assert response["op"] == op
      assert response["body"] == response_body
      assert Command.validate_response(response) == :ok
    end
  end

  test "command specs cover every MVP command with schemas and error paths" do
    assert Command.command_names() == [
             "metadata",
             "reset",
             "eval",
             "poke",
             "tick",
             "cycle",
             "peek",
             "finish?",
             "shutdown"
           ]

    assert Enum.map(Command.command_specs(), & &1.name) == Command.command_names()

    for command <- Command.command_names() do
      spec = Command.command_spec!(command)

      assert is_map(spec.request)
      assert is_map(spec.response)
      assert is_binary(spec.wrapper_operation)
      assert spec.wrapper_operation != ""
      assert "invalid_request" in spec.errors
      assert "unsupported_command" in spec.errors
    end
  end

  test "builds and validates every MVP successful response" do
    response_bodies = %{
      "metadata" => %{"top" => "Counter", "signals" => [], "cycle" => 0},
      "reset" => %{"cycle" => 2, "reset" => %{"cycles" => 2}},
      "eval" => %{"time" => 0, "cycle" => 2},
      "poke" => %{"signal" => "enable", "value" => @encoded_one, "cycle" => 2},
      "tick" => %{"clock" => "clk", "cycles" => 1, "cycle" => 3},
      "cycle" => %{"clock" => "clk", "cycles" => 5, "time" => 10, "cycle" => 8},
      "peek" => %{"signal" => "count", "value" => @encoded_count, "cycle" => 8},
      "finish?" => %{"finished" => false, "time" => 10, "cycle" => 8},
      "shutdown" => %{"status" => "closing"}
    }

    for {command, index} <- Enum.with_index(Command.command_names(), 1) do
      assert {:ok, response} = Command.ok_response(index, command, response_bodies[command])

      assert response["id"] == index
      assert response["kind"] == "response"
      assert response["op"] == command
      assert response["body"] == response_bodies[command]

      assert Command.validate_response(response) == :ok
    end
  end

  test "error responses preserve request id and operation" do
    assert {:ok, request} = Command.request("peek", 42, %{"signal" => "missing"})

    assert {:ok, error} =
             Command.error_response(
               request,
               "invalid_signal",
               "unknown signal",
               %{"signal" => "missing"}
             )

    assert error["id"] == 42
    assert error["op"] == "peek"
    assert error["kind"] == "error"
    assert error["body"]["code"] == "invalid_signal"
    assert error["body"]["message"] == "unknown signal"
    assert error["body"]["details"] == %{"signal" => "missing"}
    assert error["body"]["fatal"] == false
    assert Command.validate_error(error) == :ok
  end

  test "documented reset-poke-tick-peek exchange matches the wire and command schemas" do
    payloads = [
      {80, ~s({"v":1,"id":1,"kind":"request","op":"reset","body":{"cycles":2,"reset":"rst_n"}})},
      {102,
       ~s({"v":1,"id":1,"kind":"response","op":"reset","body":{"cycle":2,"reset":{"cycles":2,"signal":"rst_n"}}})},
      {101,
       ~s({"v":1,"id":2,"kind":"request","op":"poke","body":{"signal":"enable","value":{"bits":"1","width":1}}})},
      {112,
       ~s({"v":1,"id":2,"kind":"response","op":"poke","body":{"signal":"enable","value":{"bits":"1","width":1},"cycle":2}})},
      {77, ~s({"v":1,"id":3,"kind":"request","op":"tick","body":{"clock":"clk","cycles":1}})},
      {88,
       ~s({"v":1,"id":3,"kind":"response","op":"tick","body":{"clock":"clk","cycles":1,"cycle":3}})},
      {69, ~s({"v":1,"id":4,"kind":"request","op":"peek","body":{"signal":"count"}})},
      {114,
       ~s({"v":1,"id":4,"kind":"response","op":"peek","body":{"signal":"count","value":{"bits":"0001","width":4},"cycle":3}})},
      {71, ~s({"v":1,"id":5,"kind":"request","op":"peek","body":{"signal":"missing"}})},
      {146,
       ~s({"v":1,"id":5,"kind":"error","op":"peek","body":{"code":"invalid_signal","message":"unknown signal","details":{"signal":"missing"},"fatal":false}})}
    ]

    for {size, payload} <- payloads do
      assert byte_size(payload) == size
      assert {:ok, frame} = SvPortSim.Protocol.frame_payload(payload)
      assert <<prefix::32, rest::binary>> = frame
      assert prefix == size
      assert rest == payload
      assert {:ok, message} = SvPortSim.Protocol.decode_payload(payload)
      assert Command.validate_message(message) == :ok
    end
  end

  test "unsupported commands are rejected during request construction and validation" do
    assert Command.request("step", 1) == {:error, {:unsupported_command, "step"}}

    envelope = %{
      "v" => SvPortSim.Protocol.version(),
      "id" => 1,
      "kind" => "request",
      "op" => "step",
      "body" => %{}
    }

    assert Command.validate_request(envelope) == {:error, {:unsupported_command, "step"}}

    assert {:ok, error} =
             Command.error_response(1, "step", "unsupported_command", "unsupported command", %{})

    assert Command.validate_error(error) == :ok
  end

  test "request body validation rejects missing and unknown fields" do
    assert Command.validate_request_body("peek", %{}) ==
             {:error, {:missing_field, "peek", "signal"}}

    assert Command.validate_request_body("peek", %{"signal" => "count", "extra" => true}) ==
             {:error, {:unknown_field, "peek", "extra"}}

    assert Command.validate_request_body("poke", %{"signal" => "enable"}) ==
             {:error, {:missing_field, "poke", "value"}}

    assert Command.validate_request_body("tick", %{"cycles" => 0}) ==
             {:error, {:invalid_field, "tick", "cycles", 0}}
  end

  test "encoded values must have matching width and canonical bit characters" do
    assert Command.validate_request_body("poke", %{
             "signal" => "data",
             "value" => %{"bits" => "10xz", "width" => 4}
           }) == :ok

    assert Command.validate_request_body("poke", %{
             "signal" => "data",
             "value" => %{"bits" => "10xz", "width" => 3}
           }) == {:error, {:invalid_encoded_width, "poke", "value", "10xz", 3}}

    assert Command.validate_request_body("poke", %{
             "signal" => "data",
             "value" => %{"bits" => "10u", "width" => 3}
           }) == {:error, {:invalid_encoded_bits, "poke", "value", "10u"}}
  end

  test "response body validation pins command-specific schemas" do
    assert Command.validate_response_body("metadata", %{
             "top" => "Counter",
             "signals" => [],
             "cycle" => 0
           }) == :ok

    assert Command.validate_response_body("metadata", %{
             "top" => "Counter",
             "signals" => [],
             "cycle" => -1
           }) ==
             {:error, {:invalid_field, "metadata", "cycle", -1}}

    assert Command.validate_response_body("reset", %{
             "cycle" => 1,
             "reset" => %{"cycles" => 1, "signal" => "rst_n"}
           }) == :ok

    assert Command.validate_response_body("shutdown", %{"status" => "closed"}) ==
             {:error, {:invalid_field, "shutdown", "status", "closed"}}
  end

  test "validate_message dispatches by envelope kind" do
    assert {:ok, request} = Command.request("metadata", 1)

    assert {:ok, response} =
             Command.ok_response(request, %{"top" => "Counter", "signals" => [], "cycle" => 0})

    assert {:ok, error} =
             Command.error_response(request, "invalid_state", "wrapper is closing", %{})

    assert Command.validate_message(request) == :ok
    assert Command.validate_message(response) == :ok
    assert Command.validate_message(error) == :ok

    assert Command.validate_message(%{"kind" => "event"}) ==
             {:error, {:invalid_message, %{"kind" => "event"}}}
  end
end
