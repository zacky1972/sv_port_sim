defmodule SvPortSim.WrapperEnvelopeFixtureTransport do
  @behaviour SvPortSim.Transport

  alias SvPortSim.Protocol

  @impl true
  def open(opts) do
    {:ok, %{notify: Keyword.get(opts, :notify), ticks: 0}}
  end

  @impl true
  def request(%{"op" => "tick"} = request, state, _timeout) do
    ticks = state.ticks + 1
    {:ok, response(request, %{"time" => ticks}), %{state | ticks: ticks}}
  end

  def request(%{"op" => "peek", "body" => %{"signal" => "missing"}} = request, state, _timeout) do
    {:ok,
     error_response(request, "invalid_signal", "unknown signal", %{"signal" => "missing"}),
     state}
  end

  def request(%{"op" => "peek", "body" => %{"signal" => "fatal"}} = request, state, _timeout) do
    {:ok,
     error_response(request, "wrapper_fault", "wrapper fault", %{"reason" => "fixture fatal"},
       fatal: true
     ), state}
  end

  def request(%{"op" => "shutdown"} = request, state, _timeout) do
    {:ok, response(request, %{"status" => "stopped"}), state}
  end

  def request(request, state, _timeout) do
    {:ok,
     error_response(request, "unsupported_command", "unsupported command", %{
       "operation" => request["op"]
     }), state}
  end

  @impl true
  def close(%{notify: nil}), do: :ok

  def close(%{notify: notify}) do
    send(notify, {:fixture_transport_closed, self()})
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

  defp error_response(request, code, message, details, opts \\ []) do
    {:ok, body} = Protocol.error_body(code, message, details, opts)

    request
    |> response(body)
    |> Map.put("kind", "error")
  end
end

defmodule SvPortSim.WrapperEnvelopeFixtureTest do
  use ExUnit.Case, async: true

  alias SvPortSim.WrapperEnvelopeFixtureTransport

  test "success response envelope returns the command-specific body" do
    {:ok, sim} = SvPortSim.start_link(transport: WrapperEnvelopeFixtureTransport)

    assert {:ok, %{"time" => 1}} = SvPortSim.tick(sim)
    assert :ok = SvPortSim.stop(sim)
  end

  test "non-fatal error envelope keeps the command loop usable" do
    {:ok, sim} = SvPortSim.start_link(transport: WrapperEnvelopeFixtureTransport)

    assert {:error,
            %{
              "code" => "invalid_signal",
              "message" => "unknown signal",
              "details" => %{"signal" => "missing"},
              "fatal" => false
            }} = SvPortSim.peek(sim, "missing")

    assert Process.alive?(sim)
    assert {:ok, %{"time" => 1}} = SvPortSim.tick(sim)
    assert :ok = SvPortSim.stop(sim)
  end

  test "fatal error envelope closes the owned transport and stops the instance" do
    {:ok, sim} =
      SvPortSim.start_link(
        transport: WrapperEnvelopeFixtureTransport,
        transport_opts: [notify: self()]
      )

    assert {:error,
            %{
              "code" => "wrapper_fault",
              "message" => "wrapper fault",
              "details" => %{"reason" => "fixture fatal"},
              "fatal" => true
            }} = SvPortSim.peek(sim, "fatal")

    refute Process.alive?(sim)
    assert_receive {:fixture_transport_closed, _pid}
  end
end
