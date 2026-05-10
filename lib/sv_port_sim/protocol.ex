defmodule SvPortSim.Protocol do
  @moduledoc """
  Runtime wire-format contract for communication between Elixir and the
  C++ wrapper process.

  ## MVP wire format

  SvPortSim protocol v1 uses a 4-byte big-endian length-prefixed frame
  followed by a UTF-8 JSON payload.

      frame = uint32_be(payload_length) <> payload
      payload = UTF-8 JSON object

  The payload is a JSON object with this common envelope:

      {
        "v": 1,
        "id": 1,
        "kind": "request",
        "op": "hello",
        "body": {}
      }

  JSON object member order is not significant. Encoded examples in this
  module use a stable minified order only for documentation.

  ## Port framing

  Elixir code should open the wrapper port with:

      [:binary, {:packet, 4}, :exit_status]

  With `{:packet, 4}`, Elixir sends and receives the JSON payload bytes.
  The BEAM adds the 4-byte length prefix on writes and strips it on reads.
  The C++ wrapper must read and write the 4-byte big-endian length prefix
  explicitly.

  ## Limits

  The maximum JSON payload size is 1 MiB.

      max_payload_size = 1_048_576

  A zero-length payload is invalid. A payload larger than the maximum size
  is a fatal protocol error.

  ## Versioning

  The MVP protocol version is `1`.

  Receivers must reject payloads with unsupported protocol versions. If a
  valid request id can be read, the receiver should return an error payload:

      {
        "v": 1,
        "id": 1,
        "kind": "error",
        "op": "protocol_error",
        "body": {
          "reason": "unsupported_version",
          "supported_versions": [1]
        }
      }

  ## Encoded examples

  Request payload:

      {"v":1,"id":1,"kind":"request","op":"hello","body":{"client":"sv_port_sim"}}

  Request frame bytes:

      <<0, 0, 0, 76>> <>
        ~s({"v":1,"id":1,"kind":"request","op":"hello","body":{"client":"sv_port_sim"}})

  Response payload:

      {"v":1,"id":1,"kind":"response","op":"hello","body":{"max_payload_size":1048576}}

  Response frame bytes:

      <<0, 0, 0, 81>> <>
        ~s({"v":1,"id":1,"kind":"response","op":"hello","body":{"max_payload_size":1048576}})

  ## Rationale

  The MVP uses length-prefixed JSON rather than line-based JSON so frame
  boundaries and message-size limits are explicit. It avoids committing to
  a bespoke binary command schema before the command protocol, signal
  metadata schema, and supported SystemVerilog data subset are finalized.
  """

  @version 1
  @max_payload_size 1_048_576
  @kinds ~w(request response error)

  @type version :: 1
  @type request_id :: non_neg_integer()
  @type kind :: String.t()
  @type operation :: String.t()
  @type envelope :: %{
          required(String.t()) => term()
        }

  @doc """
  Returns the MVP protocol version.
  """
  @spec version() :: version()
  def version, do: @version

  @doc """
  Returns the maximum JSON payload size in bytes.
  """
  @spec max_payload_size() :: pos_integer()
  def max_payload_size, do: @max_payload_size

  @doc """
  Returns the recommended Elixir port options for the MVP wire format.
  """
  @spec port_options() :: [:binary | :exit_status | {:packet, 4}]
  def port_options, do: [:binary, {:packet, 4}, :exit_status]

  @doc """
  Encodes a protocol envelope into JSON payload bytes.

  This returns the payload only. When using `{:packet, 4}`, do not manually
  prepend the length prefix before passing data to `Port.command/2`.
  """
  @spec encode_payload(envelope()) :: {:ok, binary()} | {:error, term()}
  def encode_payload(message) when is_map(message) do
    with :ok <- validate_envelope(message) do
      payload = JSON.encode!(message)

      with :ok <- validate_payload_size(payload) do
        {:ok, payload}
      end
    end
  rescue
    exception ->
      {:error, {:json_encode_failed, Exception.message(exception)}}
  end

  def encode_payload(message), do: {:error, {:invalid_envelope, message}}

  @doc """
  Decodes JSON payload bytes into a protocol envelope.
  """
  @spec decode_payload(binary()) :: {:ok, envelope()} | {:error, term()}
  def decode_payload(payload) when is_binary(payload) do
    with :ok <- validate_payload_size(payload),
         {:ok, decoded} <- decode_json(payload),
         :ok <- validate_envelope(decoded) do
      {:ok, decoded}
    end
  end

  def decode_payload(payload), do: {:error, {:invalid_payload, payload}}

  @doc """
  Builds a full wire frame for documentation and low-level tests.

  In normal Elixir port usage with `{:packet, 4}`, callers should send only
  the JSON payload. This helper exists to pin the externally visible frame
  format.
  """
  @spec frame_payload(binary()) :: {:ok, binary()} | {:error, term()}
  def frame_payload(payload) when is_binary(payload) do
    with :ok <- validate_payload_size(payload) do
      {:ok, <<byte_size(payload)::32-big, payload::binary>>}
    end
  end

  def frame_payload(payload), do: {:error, {:invalid_payload, payload}}

  @doc """
  Validates the common protocol envelope.
  """
  @spec validate_envelope(term()) :: :ok | {:error, term()}
  def validate_envelope(%{
        "v" => @version,
        "id" => id,
        "kind" => kind,
        "op" => op,
        "body" => body
      })
      when is_integer(id) and id >= 0 and is_binary(kind) and is_binary(op) and is_map(body) do
    cond do
      kind not in @kinds ->
        {:error, {:invalid_kind, kind}}

      byte_size(op) == 0 ->
        {:error, :empty_operation}

      true ->
        :ok
    end
  end

  def validate_envelope(%{"v" => version}) when is_integer(version) do
    {:error, {:unsupported_version, version, @version}}
  end

  def validate_envelope(message), do: {:error, {:invalid_envelope, message}}

  defp validate_payload_size(payload) do
    size = byte_size(payload)

    cond do
      size == 0 ->
        {:error, :empty_payload}

      size > @max_payload_size ->
        {:error, {:payload_too_large, size, @max_payload_size}}

      true ->
        :ok
    end
  end

  defp decode_json(payload) do
    case JSON.decode(payload) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:json_decode_failed, reason}}
    end
  end
end
