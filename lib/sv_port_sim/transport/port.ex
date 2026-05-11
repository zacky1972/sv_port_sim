defmodule SvPortSim.Transport.Port do
  @moduledoc """
  `SvPortSim.Transport` implementation backed by an Erlang port.

  The wrapper process is opened with the port options recommended by
  `SvPortSim.Protocol.port_options/0`, namely binary mode, four-byte packet
  framing, and exit-status reporting. With `{:packet, 4}`, the BEAM sends and
  receives only the JSON payload bytes while the external wrapper reads and
  writes the four-byte big-endian length prefix itself.
  """

  @behaviour SvPortSim.Transport

  alias SvPortSim.Protocol

  @impl true
  def open(opts) do
    executable = Keyword.get(opts, :executable)
    args = Keyword.get(opts, :args, [])

    with :ok <- validate_executable(executable),
         :ok <- validate_args(args) do
      port_options = Protocol.port_options() ++ [args: args]
      {:ok, %{port: Port.open({:spawn_executable, executable}, port_options)}}
    end
  rescue
    exception -> {:error, {:port_open_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:port_open_failed, {kind, reason}}}
  end

  @impl true
  def request(request, %{port: port} = state, timeout) do
    with {:ok, payload} <- Protocol.encode_payload(request),
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

  defp receive_response(port, _request, state, :infinity) do
    receive do
      {^port, {:data, payload}} ->
        decode_response(payload, state)

      {^port, {:exit_status, status}} ->
        runtime_failure({:exit_status, status}, state)

      {^port, message} ->
        runtime_failure({:malformed_output, message}, state)
    end
  end

  defp receive_response(port, request, state, timeout) do
    receive do
      {^port, {:data, payload}} ->
        decode_response(payload, state)

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

  defp decode_response(payload, state) do
    case Protocol.decode_payload(payload) do
      {:ok, response} ->
        {:ok, response, state}

      {:error, reason} ->
        runtime_failure(:malformed_output, %{"reason" => inspect(reason)}, state)
    end
  end

  defp runtime_failure(reason, state), do: runtime_failure(reason, %{}, state)

  defp runtime_failure(reason, details, state) do
    case Protocol.runtime_failure(reason, details) do
      {:error, body} when is_map(body) -> {:error, body, state}
      {:error, error} -> {:error, error, state}
    end
  end
end
