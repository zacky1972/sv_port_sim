defmodule SvPortSimTest.ScriptedTransport do
  @behaviour SvPortSim.Transport

  alias SvPortSim.Protocol

  def open(opts) do
    {:ok,
     %{
       signals: Keyword.get(opts, :signals, %{}),
       notify: Keyword.get(opts, :notify),
       fail_on: Keyword.get(opts, :fail_on)
     }}
  end

  def request(%{"op" => "reset"} = request, state, _timeout) do
    {:ok, response(request, request["body"]), %{state | signals: %{}}}
  end

  def request(%{"op" => "tick"} = request, state, _timeout) do
    {:ok, response(request, request["body"]), state}
  end

  def request(%{"op" => "poke"} = request, state, _timeout) do
    signal = request["body"]["signal"]
    value = request["body"]["value"]

    next_state = %{state | signals: Map.put(state.signals, signal, value)}

    {:ok, response(request, %{"signal" => signal, "value" => value}), next_state}
  end

  def request(%{"op" => "peek", "body" => %{"signal" => "missing"}} = request, state, _timeout) do
    {:ok, error_response(request, "invalid_signal", "unknown signal", %{"signal" => "missing"}),
     state}
  end

  def request(%{"op" => "peek", "body" => %{"signal" => "fatal"}} = request, state, _timeout) do
    {:ok,
     error_response(request, "timeout", "simulator response timed out", %{"signal" => "fatal"}),
     state}
  end

  def request(%{"op" => "peek"} = request, state, _timeout) do
    signal = request["body"]["signal"]
    value = Map.get(state.signals, signal, %{"bits" => "0", "width" => 1})

    {:ok, response(request, %{"value" => value}), state}
  end

  def request(%{"op" => "shutdown"} = request, state, _timeout) do
    {:ok, response(request, %{}), state}
  end

  def close(%{notify: nil}), do: :ok

  def close(%{notify: notify}) do
    send(notify, {:transport_closed, self()})
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

defmodule SvPortSimTest.MalformedTransport do
  @behaviour SvPortSim.Transport

  def open(_opts), do: {:ok, :state}

  def request(request, state, _timeout) do
    response = %{
      "v" => SvPortSim.Protocol.version(),
      "id" => request["id"] + 1,
      "kind" => "response",
      "op" => request["op"],
      "body" => %{}
    }

    {:ok, response, state}
  end

  def close(_state), do: :ok
end

defmodule SvPortSimTest do
  use ExUnit.Case, async: true

  doctest SvPortSim

  alias SvPortSimTest.MalformedTransport
  alias SvPortSimTest.ScriptedTransport

  test "public_functions/0 pins the initial API contract" do
    assert SvPortSim.public_functions() == [
             {:child_spec, 1},
             {:start_link, 1},
             {:start, 1},
             {:reset, 1},
             {:reset, 2},
             {:tick, 1},
             {:tick, 2},
             {:poke, 3},
             {:poke, 4},
             {:peek, 2},
             {:peek, 3},
             {:stop, 1},
             {:stop, 2},
             {:public_functions, 0}
           ]
  end

  test "normal lifecycle reset, tick, poke, peek, and stop" do
    {:ok, sim} = SvPortSim.start_link(transport: ScriptedTransport)

    assert {:ok, %{"cycles" => 2, "reset" => "rst_n"}} =
             SvPortSim.reset(sim, cycles: 2, reset: :rst_n)

    assert {:ok, %{"cycles" => 3, "clock" => "clk"}} =
             SvPortSim.tick(sim, cycles: 3, clock: "clk")

    assert {:ok, %{"signal" => "enable", "value" => %{"bits" => "1", "width" => 1}}} =
             SvPortSim.poke(sim, :enable, %{bits: "1", width: 1})

    assert {:ok, %{"value" => %{"bits" => "1", "width" => 1}}} = SvPortSim.peek(sim, "enable")
    assert :ok = SvPortSim.stop(sim)
  end

  test "default transport requires executable" do
    assert {:error, {:missing_required_option, :executable}} = SvPortSim.start_link([])
  end

  test "start accepts transport_opts and closes the owned transport on stop" do
    {:ok, sim} =
      SvPortSim.start_link(transport: ScriptedTransport, transport_opts: [notify: self()])

    assert :ok = SvPortSim.stop(sim)
    assert_receive {:transport_closed, _pid}
  end

  test "local validation returns canonical invalid_request errors" do
    {:ok, sim} = SvPortSim.start_link(transport: ScriptedTransport)

    assert {:error, %{"code" => "invalid_request", "fatal" => false}} =
             SvPortSim.tick(sim, cycles: 0)

    assert {:error, %{"code" => "invalid_request", "fatal" => false}} = SvPortSim.peek(sim, "")

    assert {:error, %{"code" => "invalid_request", "fatal" => false}} =
             SvPortSim.poke(sim, :data, %{bits: "10", width: 1})

    assert {:error, %{"code" => "invalid_request", "fatal" => false}} =
             SvPortSim.reset(sim, extra: true)

    assert :ok = SvPortSim.stop(sim)
  end

  test "wrapper errors are returned through the protocol error body" do
    {:ok, sim} = SvPortSim.start_link(transport: ScriptedTransport)

    assert {:error,
            %{"code" => "invalid_signal", "fatal" => false, "details" => %{"signal" => "missing"}}} =
             SvPortSim.peek(sim, "missing")

    assert Process.alive?(sim)
    assert :ok = SvPortSim.stop(sim)
  end

  test "fatal wrapper errors close the transport and stop the instance" do
    {:ok, sim} =
      SvPortSim.start_link(transport: ScriptedTransport, transport_opts: [notify: self()])

    assert {:error, %{"code" => "timeout", "fatal" => true}} = SvPortSim.peek(sim, "fatal")
    refute Process.alive?(sim)
    assert_receive {:transport_closed, _pid}
  end

  test "malformed or mismatched responses become fatal malformed_output errors" do
    {:ok, sim} = SvPortSim.start_link(transport: MalformedTransport)

    assert {:error, %{"code" => "malformed_output", "fatal" => true}} = SvPortSim.tick(sim)
    refute Process.alive?(sim)
  end

  test "child_spec/1 delegates to start_link/1" do
    assert %{
             id: :alu_sim,
             start: {SvPortSim, :start_link, [[transport: ScriptedTransport]]},
             type: :worker,
             restart: :permanent,
             shutdown: 5_000
           } = SvPortSim.child_spec(transport: ScriptedTransport, id: :alu_sim)
  end
end
