defmodule SvPortSim.Protocol.CommandTest do
  use ExUnit.Case, async: true

  doctest SvPortSim.Protocol.Command

  alias SvPortSim.Protocol.Command

  @encoded_one %{"bits" => "1", "width" => 1}
  @encoded_count %{"bits" => "0010", "width" => 4}

  @command_cases [
    %{
      op: "metadata",
      request: %{},
      response: %{"top" => "Counter", "signals" => [], "cycle" => 0}
    },
    %{
      op: "reset",
      request: %{"cycles" => 2},
      response: %{"cycle" => 2, "reset" => %{"cycles" => 2}}
    },
    %{
      op: "eval",
      request: %{},
      response: %{"time" => 0, "cycle" => 2}
    },
    %{
      op: "poke",
      request: %{"signal" => "enable", "value" => @encoded_one},
      response: %{"signal" => "enable", "value" => @encoded_one, "cycle" => 2}
    },
    %{
      op: "tick",
      request: %{"clock" => "clk", "cycles" => 3},
      response: %{"clock" => "clk", "cycles" => 1, "cycle" => 3}
    },
    %{
      op: "cycle",
      request: %{"clock" => "clk", "cycles" => 5},
      response: %{"clock" => "clk", "cycles" => 5, "time" => 10, "cycle" => 8}
    },
    %{
      op: "peek",
      request: %{"signal" => "count"},
      response: %{"signal" => "count", "value" => @encoded_count, "cycle" => 8}
    },
    %{
      op: "finish?",
      request: %{},
      response: %{"finished" => false, "time" => 10, "cycle" => 8}
    },
    %{
      op: "shutdown",
      request: %{},
      response: %{"status" => "closing"}
    }
  ]

  @expected_commands for %{op: op} <- @command_cases, do: op

  defp command_cases, do: @command_cases
  defp expected_commands, do: @expected_commands

  defp command_case!(op) do
    case Enum.find(command_cases(), &(&1.op == op)) do
      nil -> raise ArgumentError, "missing command test fixture for #{inspect(op)}"
      command_case -> command_case
    end
  end

  defp assert_request_envelope(request, id, command, body) do
    assert request["v"] == SvPortSim.Protocol.version()
    assert request["id"] == id
    assert request["kind"] == "request"
    assert request["op"] == command
    assert request["body"] == body

    assert Command.validate_request(request) == :ok
  end

  defp assert_response_envelope(response, id, command, body) do
    assert response["v"] == SvPortSim.Protocol.version()
    assert response["id"] == id
    assert response["kind"] == "response"
    assert response["op"] == command
    assert response["body"] == body

    assert Command.validate_response(response) == :ok
  end

  test "command fixtures and specs cover every MVP command in protocol order" do
    assert expected_commands() == [
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

    assert Command.command_names() == expected_commands()
    assert Enum.map(Command.command_specs(), & &1.name) == expected_commands()

    for command <- expected_commands() do
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
    for {%{op: command, request: body}, index} <- Enum.with_index(command_cases(), 1) do
      assert {:ok, request} = Command.request(command, index, body)
      assert_request_envelope(request, index, command, body)
    end
  end

  test "builds and validates every MVP successful response" do
    for {%{op: command, response: body}, index} <- Enum.with_index(command_cases(), 1) do
      assert {:ok, response} = Command.ok_response(index, command, body)
      assert_response_envelope(response, index, command, body)
    end
  end

  test "Issue 34 simulation-control commands validate through request-derived responses" do
    for {command, index} <- Enum.with_index(~w(eval cycle finish?), 1) do
      %{request: request_body, response: response_body} = command_case!(command)

      assert {:ok, request} = Command.request(command, index, request_body)
      assert_request_envelope(request, index, command, request_body)

      assert {:ok, response} = Command.ok_response(request, response_body)
      assert_response_envelope(response, index, command, response_body)
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
