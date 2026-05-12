defmodule SvPortSimTest.FatalShutdownTransport do
  @behaviour SvPortSim.Transport

  alias SvPortSim.Protocol

  def open(opts) do
    {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}
  end

  def request(%{"op" => "shutdown"} = request, state, _timeout) do
    {:ok, error_response(request, "timeout", "simulator response timed out", %{}), state}
  end

  def close(state) do
    send(state.test_pid, {:transport_closed, self()})
    :ok
  end

  defp response(request, body) do
    %{
      "v" => Protocol.version(),
      "id" => request["id"],
      "kind" => "response",
      "op" => request["op"],
      "body" => body
    }
  end

  defp error_response(request, code, message, details) do
    {:ok, body} = Protocol.error_body(code, message, details)

    request
    |> response(body)
    |> Map.put("kind", "error")
  end
end
