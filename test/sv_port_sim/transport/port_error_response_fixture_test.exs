defmodule SvPortSim.Transport.PortErrorResponseFixtureTest do
  use ExUnit.Case, async: false

  alias SvPortSim.Protocol
  alias SvPortSim.Transport.Port, as: PortTransport

  @fixture Path.expand("../../fixtures/port_error_response_fixture", __DIR__)
  @timeout 5_000

  setup_all do
    File.chmod!(@fixture, 0o755)
    :ok
  end

  describe "fixture error response framing" do
    test "fixture emits a raw 4-byte length-prefixed error frame and stays alive" do
      port = Port.open({:spawn_executable, @fixture}, [:binary, :exit_status])
      on_exit(fn -> close_port(port) end)

      send_raw_request(port, request(10, "peek", %{"signal" => "missing"}))
      assert {:ok, error_payload} = receive_raw_frame(port, @timeout)
      assert_error_envelope(error_payload, 10)

      send_raw_request(port, request(11, "stop", %{}))
      assert {:ok, stop_payload} = receive_raw_frame(port, @timeout)
      assert {:ok, %{"id" => 11, "kind" => "response", "op" => "stop"}} = Protocol.decode_payload(stop_payload)
    end

    test "BEAM packet mode strips the fixture prefix and receives the error JSON payload" do
      port = Port.open({:spawn_executable, @fixture}, Protocol.port_options())
      on_exit(fn -> close_port(port) end)

      send_packet_request(port, request(20, "peek", %{"signal" => "missing"}))
      assert_receive {^port, {:data, error_payload}}, @timeout
      assert <<?{, _rest::binary>> = error_payload
      assert_error_envelope(error_payload, 20)

      send_packet_request(port, request(21, "peek", %{"signal" => "count"}))
      assert_receive {^port, {:data, response_payload}}, @timeout

      assert {:ok,
              %{
                "id" => 21,
                "kind" => "response",
                "op" => "peek",
                "body" => %{"signal" => "count", "value" => %{"bits" => "0", "width" => 1}}
              }} = Protocol.decode_payload(response_payload)

      send_packet_request(port, request(22, "stop", %{}))
      assert_receive {^port, {:data, stop_payload}}, @timeout
      assert {:ok, %{"id" => 22, "kind" => "response", "op" => "stop"}} = Protocol.decode_payload(stop_payload)
      assert_receive {^port, {:exit_status, 0}}, @timeout
    end

    test "Transport.Port.request accepts the fixture error envelope without timing out" do
      {:ok, state} = PortTransport.open(executable: @fixture)
      on_exit(fn -> PortTransport.close(state) end)

      assert {:ok, error_envelope, state} =
               PortTransport.request(request(30, "peek", %{"signal" => "missing"}), state, @timeout)

      assert %{"id" => 30, "kind" => "error", "op" => "peek"} = error_envelope
      assert error_envelope["body"] == invalid_signal_error_body()

      assert {:ok, response_envelope, state} =
               PortTransport.request(request(31, "peek", %{"signal" => "count"}), state, @timeout)

      assert %{
               "id" => 31,
               "kind" => "response",
               "op" => "peek",
               "body" => %{"signal" => "count", "value" => %{"bits" => "0", "width" => 1}}
             } = response_envelope

      assert {:ok, %{"id" => 32, "kind" => "response", "op" => "stop"}, _state} =
               PortTransport.request(request(32, "stop", %{}), state, @timeout)
    end
  end

  defp request(id, op, body) do
    %{
      "v" => Protocol.version(),
      "id" => id,
      "kind" => "request",
      "op" => op,
      "body" => body
    }
  end

  defp send_raw_request(port, request) do
    {:ok, payload} = Protocol.encode_payload(request)
    {:ok, frame} = Protocol.frame_payload(payload)
    assert Port.command(port, frame)
  end

  defp send_packet_request(port, request) do
    {:ok, payload} = Protocol.encode_payload(request)
    assert Port.command(port, payload)
  end

  defp receive_raw_frame(port, timeout), do: receive_raw_frame(port, <<>>, timeout)

  defp receive_raw_frame(port, buffer, timeout) do
    case extract_frame(buffer) do
      {:ok, payload, _rest} ->
        {:ok, payload}

      :more ->
        receive do
          {^port, {:data, data}} -> receive_raw_frame(port, buffer <> data, timeout)
          {^port, {:exit_status, status}} -> {:error, {:exit_status, status, buffer}}
        after
          timeout -> {:error, {:timeout, buffer}}
        end
    end
  end

  defp extract_frame(<<length::32, rest::binary>>) when byte_size(rest) >= length do
    <<payload::binary-size(length), remainder::binary>> = rest
    {:ok, payload, remainder}
  end

  defp extract_frame(_buffer), do: :more

  defp assert_error_envelope(payload, id) do
    assert {:ok,
            %{
              "v" => 1,
              "id" => ^id,
              "kind" => "error",
              "op" => "peek",
              "body" => body
            }} = Protocol.decode_payload(payload)

    assert body == invalid_signal_error_body()
  end

  defp invalid_signal_error_body do
    %{
      "code" => "invalid_signal",
      "message" => "unknown signal",
      "details" => %{"signal" => "missing"},
      "fatal" => false
    }
  end

  defp close_port(port) when is_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
