defmodule SvPortSim.Transport.PortCodecDelegationTest.RecordingCodec do
  @moduledoc false

  alias SvPortSim.Protocol

  def set_owner(pid) when is_pid(pid) do
    Application.put_env(:sv_port_sim, __MODULE__, pid)
  end

  def clear_owner do
    Application.delete_env(:sv_port_sim, __MODULE__)
  end

  def encode_request(id, command, body) do
    send(owner!(), {:codec_encode_request, id, command, body})

    request = %{
      "v" => Protocol.version(),
      "id" => id,
      "kind" => "request",
      "op" => normalize_command(command),
      "body" => body
    }

    Protocol.encode_payload(request)
  end

  def decode_response(payload, expected_id, expected_command) do
    send(owner!(), {:codec_decode_response, payload, expected_id, expected_command})

    with {:ok, response} <- Protocol.decode_payload(payload),
         :ok <- validate_response(response, expected_id, normalize_command(expected_command)) do
      {:ok, response}
    else
      {:error, reason} -> malformed(reason)
    end
  end

  defp validate_response(
         %{"id" => id, "op" => op, "kind" => kind, "body" => body},
         expected_id,
         expected_op
       )
       when id == expected_id and op == expected_op and kind in ["response", "error"] and
              is_map(body) do
    :ok
  end

  defp validate_response(response, expected_id, expected_op) do
    {:error,
     {:unexpected_response,
      %{response: response, expected_id: expected_id, expected_op: expected_op}}}
  end

  defp malformed(reason) do
    Protocol.runtime_failure(:malformed_output, %{"reason" => inspect(reason)})
  end

  defp normalize_command(:stop), do: "shutdown"
  defp normalize_command(command) when is_atom(command), do: Atom.to_string(command)
  defp normalize_command(command) when is_binary(command), do: command

  defp owner! do
    Application.fetch_env!(:sv_port_sim, __MODULE__)
  end
end

defmodule SvPortSim.Transport.PortCodecDelegationTest do
  use ExUnit.Case, async: false

  alias SvPortSim.Transport.Port, as: PortTransport
  alias SvPortSim.Transport.PortCodecDelegationTest.RecordingCodec

  @request_timeout 5_000

  setup_all do
    File.chmod!(fixture_executable(), 0o755)
    :ok
  end

  setup do
    RecordingCodec.set_owner(self())

    on_exit(fn ->
      RecordingCodec.clear_owner()
    end)

    :ok
  end

  test "raw port transport delegates request encoding and response decoding to the configured codec" do
    trace = trace_path()

    {:ok, state} =
      PortTransport.open(
        executable: fixture_executable(),
        args: ["--trace", trace],
        codec: RecordingCodec
      )

    on_exit(fn -> PortTransport.close(state) end)

    request = %{
      "v" => SvPortSim.Protocol.version(),
      "id" => 7,
      "kind" => "request",
      "op" => "peek",
      "body" => %{"signal" => "count"}
    }

    assert {:ok,
            %{
              "v" => 1,
              "id" => 7,
              "kind" => "response",
              "op" => "peek",
              "body" => %{"signal" => "count", "value" => %{"bits" => "0000", "width" => 4}}
            }, _state} = PortTransport.request(request, state, @request_timeout)

    assert_receive {:codec_encode_request, 7, "peek", %{"signal" => "count"}}
    assert_receive {:codec_decode_response, payload, 7, "peek"}
    assert is_binary(payload)

    trace = read_trace(trace)
    assert_frame_lengths!(trace)

    assert trace |> Enum.filter(&(&1["dir"] == "in")) |> Enum.map(& &1["payload"]["op"]) ==
             ["peek"]
  end

  defp fixture_executable do
    Path.expand("../../fixtures/fake_protocol_sim", __DIR__)
  end

  defp trace_path do
    path =
      Path.join(
        System.tmp_dir!(),
        "sv_port_sim_port_codec_delegation_#{System.unique_integer([:positive, :monotonic])}.jsonl"
      )

    File.rm(path)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp read_trace(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      {:ok, record} = JSON.decode(line)
      record
    end)
  end

  defp assert_frame_lengths!(trace) do
    Enum.each(trace, fn record ->
      length = record["length"]
      assert length == byte_size(record["payload_text"])
      assert record["prefix_hex"] == Base.encode16(<<length::32>>, case: :lower)
    end)
  end
end
