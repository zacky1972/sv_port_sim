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
