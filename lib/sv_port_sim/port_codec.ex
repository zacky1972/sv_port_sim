defmodule SvPortSim.PortCodec do
  @moduledoc """
  Stateless request/response codec for simulator port payloads.

  `SvPortSim.Server` is responsible for allocating request ids and managing the
  simulator process. This module only translates caller-supplied request ids,
  commands, and bodies to JSON payload bytes, and translates wrapper response
  payload bytes back to public runtime return shapes.

  ## Examples

      iex> {:ok, payload} = SvPortSim.PortCodec.encode_request(1, :peek, %{"signal" => "count"})
      iex> {:ok, envelope} = SvPortSim.Protocol.decode_payload(payload)
      iex> {envelope["kind"], envelope["op"], envelope["body"]}
      {"request", "peek", %{"signal" => "count"}}

      iex> response = %{
      ...>   "v" => SvPortSim.Protocol.version(),
      ...>   "id" => 1,
      ...>   "kind" => "response",
      ...>   "op" => "peek",
      ...>   "body" => %{"value" => %{"bits" => "0001", "width" => 4}}
      ...> }
      iex> {:ok, payload} = SvPortSim.Protocol.encode_payload(response)
      iex> SvPortSim.PortCodec.decode_response(payload, 1, :peek)
      {:ok, %{"value" => %{"bits" => "0001", "width" => 4}}}

      iex> {:error, error} = SvPortSim.PortCodec.decode_response("{", 1, :peek)
      iex> {error["code"], error["fatal"]}
      {"malformed_output", true}
  """

  alias SvPortSim.Protocol

  @atom_commands %{
    reset: "reset",
    poke: "poke",
    peek: "peek",
    eval: "eval",
    tick: "tick",
    cycle: "cycle",
    transaction: "transaction",
    stop: "shutdown"
  }

  @operation_names ~w(reset poke peek eval tick cycle transaction shutdown)

  @type command ::
          :reset
          | :poke
          | :peek
          | :eval
          | :tick
          | :cycle
          | :transaction
          | :stop
          | String.t()

  @doc """
  Encodes a simulator request envelope into JSON payload bytes.

  The returned binary is the JSON payload only. It must not include the
  four-byte port packet prefix because `{:packet, 4}` framing is handled by the
  BEAM port.

  ## Examples

      iex> {:ok, payload} = SvPortSim.PortCodec.encode_request(7, :tick, %{"cycles" => 2, "clock" => "clk"})
      iex> {:ok, decoded} = SvPortSim.Protocol.decode_payload(payload)
      iex> {decoded["id"], decoded["kind"], decoded["op"], decoded["body"]["cycles"]}
      {7, "request", "tick", 2}

      iex> {:ok, payload} = SvPortSim.PortCodec.encode_request(8, :stop, %{})
      iex> {:ok, decoded} = SvPortSim.Protocol.decode_payload(payload)
      iex> decoded["op"]
      "shutdown"

      iex> SvPortSim.PortCodec.encode_request(-1, :peek, %{"signal" => "count"})
      {:error, {:invalid_request_id, -1}}

      iex> SvPortSim.PortCodec.encode_request(1, :not_a_command, %{})
      {:error, {:unsupported_command, :not_a_command}}
  """
  @spec encode_request(term(), command(), term()) :: {:ok, binary()} | {:error, term()}
  def encode_request(id, command, body) do
    with :ok <- validate_request_id(id),
         {:ok, op} <- normalize_command(command),
         :ok <- validate_request_body(body) do
      Protocol.encode_payload(%{
        "v" => Protocol.version(),
        "id" => id,
        "kind" => "request",
        "op" => op,
        "body" => body
      })
    end
  end

  @doc """
  Decodes a simulator response payload into a public runtime result.

  Successful response envelopes become `{:ok, body}`. Error envelopes become
  `{:error, error_body}` with a normalized canonical error body. Malformed JSON,
  incomplete payloads, non-response envelopes, and mismatched ids or operations
  are converted into fatal `"malformed_output"` runtime errors.

  ## Examples

      iex> response = %{
      ...>   "v" => SvPortSim.Protocol.version(),
      ...>   "id" => 5,
      ...>   "kind" => "response",
      ...>   "op" => "eval",
      ...>   "body" => %{"settled" => true}
      ...> }
      iex> {:ok, payload} = SvPortSim.Protocol.encode_payload(response)
      iex> SvPortSim.PortCodec.decode_response(payload, 5, "eval")
      {:ok, %{"settled" => true}}

      iex> {:ok, body} = SvPortSim.Protocol.error_body("invalid_signal", "unknown signal", %{"signal" => "missing"})
      iex> error = %{
      ...>   "v" => SvPortSim.Protocol.version(),
      ...>   "id" => 6,
      ...>   "kind" => "error",
      ...>   "op" => "peek",
      ...>   "body" => body
      ...> }
      iex> {:ok, payload} = SvPortSim.Protocol.encode_payload(error)
      iex> {:error, returned} = SvPortSim.PortCodec.decode_response(payload, 6, :peek)
      iex> {returned["code"], returned["fatal"], returned["details"]}
      {"invalid_signal", false, %{"signal" => "missing"}}

      iex> response = %{
      ...>   "v" => SvPortSim.Protocol.version(),
      ...>   "id" => 10,
      ...>   "kind" => "response",
      ...>   "op" => "peek",
      ...>   "body" => %{}
      ...> }
      iex> {:ok, payload} = SvPortSim.Protocol.encode_payload(response)
      iex> {:error, error} = SvPortSim.PortCodec.decode_response(payload, 11, :peek)
      iex> {error["code"], error["details"]["expected_id"], error["details"]["actual_id"]}
      {"malformed_output", 11, 10}
  """
  @spec decode_response(binary(), term(), command()) :: {:ok, map()} | {:error, map()}
  def decode_response(payload, expected_id, expected_command) do
    with {:ok, expected_op} <- normalize_command(expected_command),
         {:ok, response} <- decode_payload(payload),
         :ok <- validate_response_kind(response),
         :ok <- validate_response_id(response, expected_id),
         :ok <- validate_response_op(response, expected_op) do
      Protocol.to_elixir_return(response)
    else
      {:error, %{} = details} -> malformed_output(details)
      {:error, reason} -> malformed_output(%{"reason" => inspect(reason)})
    end
  end

  defp validate_request_id(id) when is_integer(id) and id >= 0, do: :ok
  defp validate_request_id(id), do: {:error, {:invalid_request_id, id}}

  defp validate_request_body(body) when is_map(body), do: :ok
  defp validate_request_body(body), do: {:error, {:invalid_request_body, body}}

  defp normalize_command(command) when is_atom(command) do
    case Map.fetch(@atom_commands, command) do
      {:ok, op} -> {:ok, op}
      :error -> {:error, {:unsupported_command, command}}
    end
  end

  defp normalize_command(command) when is_binary(command) do
    if command in @operation_names do
      {:ok, command}
    else
      {:error, {:unsupported_command, command}}
    end
  end

  defp normalize_command(command), do: {:error, {:unsupported_command, command}}

  defp decode_payload(payload) do
    case Protocol.decode_payload(payload) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_response_kind(%{"kind" => kind}) when kind in ["response", "error"], do: :ok

  defp validate_response_kind(%{"kind" => kind}) do
    {:error, %{"expected_kind" => ["response", "error"], "actual_kind" => kind}}
  end

  defp validate_response_kind(response), do: {:error, {:invalid_response_envelope, response}}

  defp validate_response_id(%{"id" => id}, expected_id) when id == expected_id, do: :ok

  defp validate_response_id(%{"id" => id}, expected_id) do
    {:error, %{"expected_id" => expected_id, "actual_id" => id}}
  end

  defp validate_response_id(response, expected_id) do
    {:error, %{"expected_id" => expected_id, "actual_id" => Map.get(response, "id")}}
  end

  defp validate_response_op(%{"op" => op}, expected_op) when op == expected_op, do: :ok

  defp validate_response_op(%{"op" => op}, expected_op) do
    {:error, %{"expected_op" => expected_op, "actual_op" => op}}
  end

  defp validate_response_op(response, expected_op) do
    {:error, %{"expected_op" => expected_op, "actual_op" => Map.get(response, "op")}}
  end

  defp malformed_output(details), do: Protocol.runtime_failure(:malformed_output, details)
end
