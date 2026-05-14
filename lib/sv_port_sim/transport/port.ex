defmodule SvPortSim.Transport.Port do
  @moduledoc """
  `SvPortSim.Transport` implementation backed by an Erlang port.

  The wrapper process is opened with the port options recommended by
  `SvPortSim.Protocol.port_options/0`, namely binary mode, four-byte packet
  framing, and exit-status reporting. With `{:packet, 4}`, the BEAM sends and
  receives only the JSON payload bytes while the external wrapper reads and
  writes the four-byte big-endian length prefix itself.

  ## Options

    * `:executable` - path to the wrapper executable. Required.
    * `:args` - command-line arguments passed to the wrapper executable.
      Defaults to `[]`.
    * `:codec` - optional request/response codec module. When omitted, this
      transport uses `SvPortSim.Protocol` directly.

  A custom codec is mainly intended for tests and alternate runtimes that need
  to observe or replace the payload boundary without replacing the whole
  transport. The module must implement:

    * `encode_request(id, op, body)`, returning `{:ok, payload}` or
      `{:error, reason}`.
    * `decode_response(payload, expected_id, expected_op)`, returning either
      `{:ok, response_envelope}`, `{:ok, response_body}`,
      `{:error, error_body}`, or `{:error, reason}`.

  When a codec returns only a successful response body, the transport wraps it
  back into a response envelope before handing it to `SvPortSim.Server`.
  """

  @behaviour SvPortSim.Transport

  alias SvPortSim.Protocol

  @impl true
  def open(opts) do
    executable = Keyword.get(opts, :executable)
    args = Keyword.get(opts, :args, [])
    codec = Keyword.get(opts, :codec)

    with :ok <- validate_executable(executable),
         :ok <- validate_args(args),
         :ok <- validate_codec(codec) do
      port_options = Protocol.port_options() ++ [args: args]

      state = %{port: Port.open({:spawn_executable, executable}, port_options)}
      {:ok, maybe_put_codec(state, codec)}
    end
  rescue
    exception -> {:error, {:port_open_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:port_open_failed, {kind, reason}}}
  end

  @impl true
  def request(request, %{port: port} = state, timeout) do
    with {:ok, payload} <- encode_request(request, state),
         true <- Port.command(port, payload) do
      receive_response(port, request, state, timeout)
    else
      # false ->
      #   runtime_failure({:port_closed, :stdin}, state)

      {:error, reason} ->
        runtime_failure(:protocol_error, %{"reason" => inspect(reason)}, state)
    end
  rescue
    exception -> runtime_failure({:wrapper_fault, Exception.message(exception)}, state)
  catch
    kind, reason -> runtime_failure({:wrapper_fault, {kind, reason}}, state)
  end

  @impl true
  def close(%{port: port}) when is_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def close(_state), do: :ok

  defp validate_executable(executable) when is_binary(executable) and byte_size(executable) > 0 do
    :ok
  end

  defp validate_executable(_executable), do: {:error, {:missing_required_option, :executable}}

  defp validate_args(args) when is_list(args) do
    if Enum.all?(args, &is_binary/1) do
      :ok
    else
      {:error, {:invalid_args, args}}
    end
  end

  defp validate_args(args), do: {:error, {:invalid_args, args}}

  defp validate_codec(nil), do: :ok
  defp validate_codec(codec) when is_atom(codec), do: :ok
  defp validate_codec(codec), do: {:error, {:invalid_codec, codec}}

  defp maybe_put_codec(state, nil), do: state
  defp maybe_put_codec(state, codec), do: Map.put(state, :codec, codec)

  defp encode_request(request, %{codec: codec}) do
    codec.encode_request(request["id"], request["op"], request["body"])
  end

  defp encode_request(request, _state), do: Protocol.encode_payload(request)

  defp receive_response(port, request, state, :infinity) do
    receive do
      {^port, {:data, payload}} ->
        decode_response(payload, request, state)

      {^port, {:exit_status, status}} ->
        runtime_failure({:exit_status, status}, state)

      {^port, message} ->
        runtime_failure({:malformed_output, message}, state)
    end
  end

  defp receive_response(port, request, state, timeout) do
    receive do
      {^port, {:data, payload}} ->
        decode_response(payload, request, state)

      {^port, {:exit_status, status}} ->
        runtime_failure({:exit_status, status}, state)

      {^port, message} ->
        runtime_failure({:malformed_output, message}, state)
    after
      timeout ->
        _ignored = close(state)
        runtime_failure({:timeout, request["id"], request["op"], timeout}, state)
    end
  end

  defp decode_response(payload, request, %{codec: codec} = state) do
    case codec.decode_response(payload, request["id"], request["op"]) do
      {:ok, %{"kind" => kind} = response} when kind in ["response", "error"] ->
        {:ok, response, state}

      {:ok, body} when is_map(body) ->
        {:ok, response_envelope(request, body), state}

      {:error, error_body} when is_map(error_body) ->
        {:error, error_body, state}

      {:error, reason} ->
        runtime_failure(:malformed_output, %{"reason" => inspect(reason)}, state)
    end
  end

  defp decode_response(payload, _request, state) do
    case Protocol.decode_payload(payload) do
      {:ok, response} ->
        {:ok, response, state}

      {:error, reason} ->
        runtime_failure(:malformed_output, %{"reason" => inspect(reason)}, state)
    end
  end

  defp response_envelope(request, body) do
    %{
      "v" => Protocol.version(),
      "id" => request["id"],
      "kind" => "response",
      "op" => request["op"],
      "body" => body
    }
  end

  defp runtime_failure(reason, state), do: runtime_failure(reason, %{}, state)

  defp runtime_failure(reason, details, state) do
    case Protocol.runtime_failure(reason, details) do
      {:error, body} when is_map(body) -> {:error, body, state}
      {:error, error} -> {:error, error, state}
    end
  end
end
