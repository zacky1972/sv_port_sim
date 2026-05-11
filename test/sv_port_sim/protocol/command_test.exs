defmodule SvPortSim.Protocol.CommandTest do
  use ExUnit.Case, async: true

  doctest SvPortSim.Protocol.Command

  alias SvPortSim.Protocol.Command

  @encoded_one %{"bits" => "1", "width" => 1}
  @encoded_count %{"bits" => "0010", "width" => 4}

  test "command specs cover every MVP command with schemas and error paths" do
    assert Command.command_names() == ["metadata", "reset", "poke", "tick", "peek", "shutdown"]
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

  test "builds and validates every MVP request" do
    requests = [
      {"metadata", %{}},
      {"reset", %{"cycles" => 2}},
      {"poke", %{"signal" => "enable", "value" => @encoded_one}},
      {"tick", %{"clock" => "clk", "cycles" => 3}},
      {"peek", %{"signal" => "count"}},
      {"shutdown", %{}}
    ]

    for {{command, body}, index} <- Enum.with_index(requests, 1) do
      assert {:ok, request} = Command.request(command, index, body)
      assert request["v"] == SvPortSim.Protocol.version()
      assert request["id"] == index
      assert request["kind"] == "request"
      assert request["op"] == command
      assert request["body"] == body
      assert Command.validate_request(request) == :ok
    end
  end

  test "builds and validates every MVP successful response" do
    response_bodies = %{
      "metadata" => %{"top" => "Counter", "signals" => [], "cycle" => 0},
      "reset" => %{"cycle" => 2, "reset" => %{"cycles" => 2}},
      "poke" => %{"signal" => "enable", "value" => @encoded_one, "cycle" => 2},
      "tick" => %{"clock" => "clk", "cycles" => 1, "cycle" => 3},
      "peek" => %{"signal" => "count", "value" => @encoded_count, "cycle" => 3},
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
