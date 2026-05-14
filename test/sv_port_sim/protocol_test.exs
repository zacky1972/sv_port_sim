defmodule SvPortSim.ProtocolTest do
  use ExUnit.Case, async: true

  alias SvPortSim.Protocol

  doctest Protocol

  describe "constants" do
    test "defines MVP protocol version" do
      assert Protocol.version() == 1
    end

    test "defines maximum payload size" do
      assert Protocol.max_payload_size() == 1_048_576
    end

    test "defines recommended port options" do
      assert Protocol.port_options() == [:binary, {:packet, 4}, :exit_status]
    end
  end

  describe "payload encoding" do
    test "encodes and decodes a valid envelope" do
      message = %{
        "v" => 1,
        "id" => 1,
        "kind" => "request",
        "op" => "hello",
        "body" => %{"client" => "sv_port_sim"}
      }

      assert {:ok, payload} = Protocol.encode_payload(message)
      assert {:ok, ^message} = Protocol.decode_payload(payload)
    end

    test "rejects unsupported protocol versions" do
      message = %{
        "v" => 2,
        "id" => 1,
        "kind" => "request",
        "op" => "hello",
        "body" => %{}
      }

      assert Protocol.encode_payload(message) == {:error, {:unsupported_version, 2, 1}}
    end

    test "rejects invalid kind" do
      message = %{
        "v" => 1,
        "id" => 1,
        "kind" => "command",
        "op" => "hello",
        "body" => %{}
      }

      assert Protocol.encode_payload(message) == {:error, {:invalid_kind, "command"}}
    end

    test "round-trips MVP simulator request envelopes used by the port codec" do
      operations = [
        {"reset", %{"cycles" => 2, "reset" => "rst_n", "clock" => "clk"}},
        {"poke", %{"signal" => "enable", "value" => %{"bits" => "1", "width" => 1}}},
        {"peek", %{"signal" => "count"}},
        {"eval", %{}},
        {"tick", %{"cycles" => 3, "clock" => "clk"}},
        {"cycle", %{"cycles" => 4, "clock" => "clk"}},
        {"transaction",
         %{
           "steps" => [
             %{
               "op" => "poke",
               "body" => %{
                 "signal" => "enable",
                 "value" => %{"bits" => "1", "width" => 1}
               }
             },
             %{"op" => "eval", "body" => %{}},
             %{"op" => "peek", "body" => %{"signal" => "count"}}
           ]
         }},
        {"shutdown", %{}}
      ]

      for {{op, body}, id} <- Enum.with_index(operations) do
        envelope = %{
          "v" => Protocol.version(),
          "id" => id,
          "kind" => "request",
          "op" => op,
          "body" => body
        }

        assert {:ok, payload} = Protocol.encode_payload(envelope)
        assert {:ok, ^envelope} = Protocol.decode_payload(payload)
      end
    end
  end

  describe "runtime return mapping" do
    test "maps successful and error response envelopes to public runtime result shapes" do
      response_body = %{"value" => %{"bits" => "1", "width" => 1}}

      assert Protocol.to_elixir_return(%{
               "v" => Protocol.version(),
               "id" => 10,
               "kind" => "response",
               "op" => "peek",
               "body" => response_body
             }) == {:ok, response_body}

      error_body = %{
        "code" => "invalid_signal",
        "message" => "unknown signal",
        "details" => %{"signal" => "missing"},
        "fatal" => false
      }

      assert Protocol.to_elixir_return(%{
               "v" => Protocol.version(),
               "id" => 11,
               "kind" => "error",
               "op" => "peek",
               "body" => error_body
             }) == {:error, error_body}
    end

    test "maps malformed decoded response envelopes to fatal malformed_output errors" do
      malformed_envelopes = [
        %{
          "v" => Protocol.version(),
          "id" => 12,
          "kind" => "response",
          "op" => "peek",
          "body" => "not an object"
        },
        %{
          "v" => Protocol.version(),
          "id" => 13,
          "kind" => "error",
          "op" => "peek",
          "body" => %{"code" => "bad_code", "message" => "bad"}
        },
        %{
          "v" => Protocol.version(),
          "id" => 14,
          "kind" => "request",
          "op" => "peek",
          "body" => %{"signal" => "count"}
        }
      ]

      for envelope <- malformed_envelopes do
        assert {:error, %{"code" => "malformed_output", "fatal" => true}} =
                 Protocol.to_elixir_return(envelope)
      end
    end
  end

  describe "wire frame examples" do
    test "frames request payload with 4-byte big-endian length" do
      payload =
        ~s({"v":1,"id":1,"kind":"request","op":"hello","body":{"client":"sv_port_sim"}})

      assert byte_size(payload) == 76
      assert Protocol.frame_payload(payload) == {:ok, <<0, 0, 0, 76>> <> payload}
    end

    test "frames response payload with 4-byte big-endian length" do
      payload =
        ~s({"v":1,"id":1,"kind":"response","op":"hello","body":{"max_payload_size":1048576}})

      assert byte_size(payload) == 81
      assert Protocol.frame_payload(payload) == {:ok, <<0, 0, 0, 81>> <> payload}
    end

    test "rejects empty payload" do
      assert Protocol.frame_payload("") == {:error, :empty_payload}
    end

    test "rejects oversized payload" do
      payload = :binary.copy("x", Protocol.max_payload_size() + 1)

      assert Protocol.frame_payload(payload) ==
               {:error, {:payload_too_large, Protocol.max_payload_size() + 1, 1_048_576}}
    end
  end
end
