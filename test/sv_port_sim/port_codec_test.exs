defmodule SvPortSim.PortCodecTest do
  use ExUnit.Case, async: true

  alias SvPortSim.PortCodec
  alias SvPortSim.Protocol

  doctest PortCodec

  @commands [
    {:reset, "reset", %{"cycles" => 2, "reset" => "rst_n", "clock" => "clk"}, %{"cycles" => 2}},
    {:poke, "poke", %{"signal" => "enable", "value" => %{"bits" => "1", "width" => 1}},
     %{"signal" => "enable"}},
    {:peek, "peek", %{"signal" => "count"}, %{"value" => %{"bits" => "00000001", "width" => 8}}},
    {:eval, "eval", %{}, %{"settled" => true}},
    {:tick, "tick", %{"cycles" => 3, "clock" => "clk"}, %{"cycles" => 3}},
    {:cycle, "cycle", %{"cycles" => 4, "clock" => "clk"}, %{"cycles" => 4}},
    {:transaction, "transaction",
     %{
       "steps" => [
         %{
           "op" => "poke",
           "body" => %{"signal" => "enable", "value" => %{"bits" => "1", "width" => 1}}
         },
         %{"op" => "tick", "body" => %{"cycles" => 1, "clock" => "clk"}},
         %{"op" => "peek", "body" => %{"signal" => "count"}}
       ]
     },
     %{
       "results" => [
         %{"op" => "poke", "body" => %{"signal" => "enable"}},
         %{"op" => "tick", "body" => %{"cycles" => 1}},
         %{
           "op" => "peek",
           "body" => %{"value" => %{"bits" => "00000010", "width" => 8}}
         }
       ]
     }},
    {:stop, "shutdown", %{}, %{}}
  ]

  describe "encode_request/3" do
    for {command, op, body, _response_body} <- @commands do
      test "encodes #{command} request envelope" do
        command = unquote(command)
        op = unquote(op)
        body = unquote(Macro.escape(body))

        assert {:ok, payload} = PortCodec.encode_request(42, command, body)
        assert is_binary(payload)

        assert {:ok, decoded} = Protocol.decode_payload(payload)

        assert decoded == %{
                 "v" => Protocol.version(),
                 "id" => 42,
                 "kind" => "request",
                 "op" => op,
                 "body" => body
               }
      end
    end

    test "accepts string operation names for callers that already normalized commands" do
      body = %{"signal" => "ready"}

      assert {:ok, payload} = PortCodec.encode_request(9, "peek", body)
      assert {:ok, decoded} = Protocol.decode_payload(payload)

      assert decoded["op"] == "peek"
      assert decoded["body"] == body
    end

    test "returns an explicit error for unknown commands" do
      assert {:error, {:unsupported_command, :not_a_command}} =
               PortCodec.encode_request(1, :not_a_command, %{})
    end

    test "returns an explicit error for invalid request bodies" do
      assert {:error, {:invalid_request_body, "not a map"}} =
               PortCodec.encode_request(1, :peek, "not a map")
    end

    test "returns an explicit error for invalid request ids" do
      assert {:error, {:invalid_request_id, -1}} =
               PortCodec.encode_request(-1, :peek, %{"signal" => "count"})
    end
  end

  describe "decode_response/3" do
    for {command, op, _request_body, response_body} <- @commands do
      test "decodes #{command} success response" do
        command = unquote(command)
        op = unquote(op)
        response_body = unquote(Macro.escape(response_body))

        payload = response_payload(42, op, response_body)

        assert PortCodec.decode_response(payload, 42, command) == {:ok, response_body}
      end
    end

    test "decodes and normalizes error responses" do
      payload =
        error_payload(7, "peek", %{
          "code" => "invalid_signal",
          "message" => "unknown signal",
          "details" => %{"signal" => "missing"}
        })

      assert {:error,
              %{
                "code" => "invalid_signal",
                "message" => "unknown signal",
                "details" => %{"signal" => "missing"},
                "fatal" => false
              }} = PortCodec.decode_response(payload, 7, :peek)
    end

    test "decodes fatal error responses without losing fatality" do
      payload =
        error_payload(8, "tick", %{
          "code" => "timeout",
          "message" => "simulator response timed out",
          "details" => %{"clock" => "clk"},
          "fatal" => true
        })

      assert {:error,
              %{
                "code" => "timeout",
                "message" => "simulator response timed out",
                "details" => %{"clock" => "clk"},
                "fatal" => true
              }} = PortCodec.decode_response(payload, 8, :tick)
    end

    test "returns malformed_output for malformed JSON" do
      assert {:error, %{"code" => "malformed_output", "fatal" => true}} =
               PortCodec.decode_response("{", 1, :peek)
    end

    test "returns malformed_output for empty payloads" do
      assert {:error, %{"code" => "malformed_output", "fatal" => true}} =
               PortCodec.decode_response("", 1, :peek)
    end

    test "returns malformed_output for incomplete response payloads" do
      incomplete_payload = ~s({"v":1,"id":1,"kind":"response","op":"peek","body":)

      assert {:error, %{"code" => "malformed_output", "fatal" => true}} =
               PortCodec.decode_response(incomplete_payload, 1, :peek)
    end

    test "returns malformed_output for envelopes that are not response or error" do
      payload =
        payload!(%{
          "v" => Protocol.version(),
          "id" => 1,
          "kind" => "request",
          "op" => "peek",
          "body" => %{"signal" => "count"}
        })

      assert {:error, %{"code" => "malformed_output", "fatal" => true}} =
               PortCodec.decode_response(payload, 1, :peek)
    end

    test "returns malformed_output for mismatched response ids" do
      payload = response_payload(2, "peek", %{"value" => %{"bits" => "1", "width" => 1}})

      assert {:error,
              %{
                "code" => "malformed_output",
                "fatal" => true,
                "details" => details
              }} = PortCodec.decode_response(payload, 1, :peek)

      assert details["expected_id"] == 1
      assert details["actual_id"] == 2
    end

    test "returns malformed_output for mismatched response operations" do
      payload = response_payload(3, "tick", %{"cycles" => 1})

      assert {:error,
              %{
                "code" => "malformed_output",
                "fatal" => true,
                "details" => details
              }} = PortCodec.decode_response(payload, 3, :peek)

      assert details["expected_op"] == "peek"
      assert details["actual_op"] == "tick"
    end

    test "returns malformed_output when a success response body is not an object" do
      payload =
        raw_payload!(%{
          "v" => Protocol.version(),
          "id" => 4,
          "kind" => "response",
          "op" => "peek",
          "body" => "not an object"
        })

      assert {:error, %{"code" => "malformed_output", "fatal" => true}} =
               PortCodec.decode_response(payload, 4, :peek)
    end

    test "returns malformed_output when an error body is invalid" do
      payload = error_payload(5, "peek", %{"code" => "bad_code", "message" => "bad"})

      assert {:error, %{"code" => "malformed_output", "fatal" => true}} =
               PortCodec.decode_response(payload, 5, :peek)
    end
  end

  describe "GenServer state independence" do
    test "uses the caller-supplied request id instead of allocating ids internally" do
      body = %{"signal" => "count"}

      assert {:ok, first_payload} = PortCodec.encode_request(100, :peek, body)
      assert {:ok, second_payload} = PortCodec.encode_request(7, :peek, body)

      assert {:ok, %{"id" => 100, "op" => "peek", "body" => ^body}} =
               Protocol.decode_payload(first_payload)

      assert {:ok, %{"id" => 7, "op" => "peek", "body" => ^body}} =
               Protocol.decode_payload(second_payload)
    end
  end

  defp response_payload(id, op, body) do
    payload!(%{
      "v" => Protocol.version(),
      "id" => id,
      "kind" => "response",
      "op" => op,
      "body" => body
    })
  end

  defp error_payload(id, op, body) do
    payload!(%{
      "v" => Protocol.version(),
      "id" => id,
      "kind" => "error",
      "op" => op,
      "body" => body
    })
  end

  defp payload!(envelope) do
    {:ok, payload} = Protocol.encode_payload(envelope)
    payload
  end

  defp raw_payload!(envelope), do: JSON.encode!(envelope)
end
