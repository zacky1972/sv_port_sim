defmodule SvPortSimTest.RecordingTransport do
  @behaviour SvPortSim.Transport

  alias SvPortSim.Protocol

  def open(opts) do
    {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid), signals: %{}}}
  end

  def request(%{"op" => "peek"} = request, state, timeout) do
    send(state.test_pid, {:transport_request, request, timeout})

    body = %{
      "value" => Map.get(state.signals, request["body"]["signal"], %{"bits" => "0", "width" => 1})
    }

    {:ok, response(request, body), state}
  end

  def request(%{"op" => "poke"} = request, state, timeout) do
    send(state.test_pid, {:transport_request, request, timeout})

    signal = request["body"]["signal"]
    value = request["body"]["value"]
    next_state = %{state | signals: Map.put(state.signals, signal, value)}

    {:ok, response(request, %{"signal" => signal, "value" => value}), next_state}
  end

  def request(request, state, timeout) do
    send(state.test_pid, {:transport_request, request, timeout})
    {:ok, response(request, request["body"]), state}
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
end
