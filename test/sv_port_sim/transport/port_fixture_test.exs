defmodule SvPortSim.Transport.PortFixtureTest do
  use ExUnit.Case, async: false

  alias SvPortSim.Transport.Port, as: PortTransport

  # These tests exercise the real OS port path and spawn the executable fixture.
  # Keep the timeout above interpreter cold-start time on slower CI machines.
  @request_timeout 5_000

  setup_all do
    File.chmod!(fixture_executable(), 0o755)
    :ok
  end

  test "public API drives a fake executable and pins length-prefixed framing" do
    trace = trace_path()
    {:ok, sim} = start_sim(trace)

    assert {:ok,
            %{
              "cycle" => 2,
              "reset" => "rst_n",
              "clock" => "clk",
              "cycles" => 2,
              "active" => 0,
              "inactive" => 1,
              "final" => 1
            }} =
             SvPortSim.reset(sim, cycles: 2, reset: :rst_n)

    assert {:ok, %{"signal" => "enable", "value" => %{"bits" => "1", "width" => 1}, "cycle" => 2}} =
             SvPortSim.poke(sim, :enable, %{bits: "1", width: 1})

    assert {:ok, %{"clock" => "clk", "cycles" => 1, "cycle" => 3}} =
             SvPortSim.tick(sim, clock: "clk")

    assert {:ok,
            %{"signal" => "count", "value" => %{"bits" => "0001", "width" => 4}, "cycle" => 3}} =
             SvPortSim.peek(sim, "count")

    assert Process.alive?(sim)
    assert :ok = SvPortSim.stop(sim)

    trace = read_trace(trace)
    assert_frame_lengths!(trace)

    inbound = trace |> Enum.filter(&(&1["dir"] == "in"))
    outbound = trace |> Enum.filter(&(&1["dir"] == "out"))

    assert Enum.map(inbound, & &1["payload"]["op"]) == [
             "reset",
             "poke",
             "tick",
             "peek",
             "shutdown"
           ]

    assert Enum.map(outbound, & &1["payload"]["op"]) == [
             "reset",
             "poke",
             "tick",
             "peek",
             "shutdown"
           ]

    assert Enum.map(inbound, & &1["payload"]["id"]) == [0, 1, 2, 3, 4]
    assert Enum.map(outbound, & &1["payload"]["id"]) == [0, 1, 2, 3, 4]

    assert hd(inbound)["payload"] == %{
             "v" => SvPortSim.Protocol.version(),
             "id" => 0,
             "kind" => "request",
             "op" => "reset",
             "body" => %{"cycles" => 2, "reset" => "rst_n"}
           }
  end

  test "non-fatal executable errors return an error body and keep the session usable" do
    trace = trace_path()
    {:ok, sim} = start_sim(trace)

    assert {:error,
            %{
              "code" => "invalid_signal",
              "fatal" => false,
              "details" => %{"signal" => "missing"}
            }} = SvPortSim.peek(sim, "missing")

    assert Process.alive?(sim)

    assert {:ok,
            %{"signal" => "count", "value" => %{"bits" => "0000", "width" => 4}, "cycle" => 0}} =
             SvPortSim.peek(sim, "count")

    assert :ok = SvPortSim.stop(sim)

    trace = read_trace(trace)
    assert_frame_lengths!(trace)

    assert [%{"payload" => %{"kind" => "error", "body" => error_body}}] =
             Enum.filter(trace, &match?(%{"dir" => "out", "payload" => %{"kind" => "error"}}, &1))

    assert error_body == %{
             "code" => "invalid_signal",
             "message" => "unknown signal",
             "details" => %{"signal" => "missing"},
             "fatal" => false
           }
  end

  test "fatal executable errors close the transport and require a new simulator" do
    trace = trace_path()
    {:ok, sim} = start_sim(trace)
    ref = Process.monitor(sim)

    assert {:error, %{"code" => "wrapper_fault", "fatal" => true}} = SvPortSim.peek(sim, "fatal")
    assert_receive {:DOWN, ^ref, :process, ^sim, :normal}, @request_timeout
    refute Process.alive?(sim)

    assert {:error, %{"code" => "port_closed", "fatal" => true}} = SvPortSim.peek(sim, "count")

    trace = read_trace(trace)
    assert_frame_lengths!(trace)

    assert [%{"payload" => %{"kind" => "error", "body" => %{"fatal" => true}}}] =
             Enum.filter(trace, &match?(%{"dir" => "out", "payload" => %{"kind" => "error"}}, &1))

    new_trace = trace_path()
    {:ok, new_sim} = start_sim(new_trace)
    assert {:ok, %{"signal" => "count"}} = SvPortSim.peek(new_sim, "count")
    assert :ok = SvPortSim.stop(new_sim)
  end

  test "malformed executable output becomes fatal malformed_output and closes the session" do
    trace = trace_path()
    {:ok, sim} = start_sim(trace)
    ref = Process.monitor(sim)

    assert {:error, %{"code" => "malformed_output", "fatal" => true}} =
             SvPortSim.peek(sim, "malformed")

    assert_receive {:DOWN, ^ref, :process, ^sim, :normal}, @request_timeout
    refute Process.alive?(sim)

    trace = read_trace(trace)
    assert_frame_lengths!(trace)

    assert Enum.any?(trace, &(&1["dir"] == "out" and &1["payload_text"] == "{"))
  end

  test "fixture also covers raw protocol operations through SvPortSim.Transport.Port" do
    trace = trace_path()
    {:ok, state} = PortTransport.open(executable: fixture_executable(), args: ["--trace", trace])
    on_exit(fn -> PortTransport.close(state) end)

    assert {:ok, %{"op" => "reset", "body" => %{"cycle" => 1}}, state} =
             PortTransport.request(request(0, "reset", %{"cycles" => 1}), state, @request_timeout)

    assert {:ok, %{"op" => "poke", "body" => %{"signal" => "enable"}}, state} =
             PortTransport.request(
               request(1, "poke", %{
                 "signal" => "enable",
                 "value" => %{"bits" => "1", "width" => 1}
               }),
               state,
               @request_timeout
             )

    assert {:ok, %{"op" => "tick", "body" => %{"clock" => "clk", "cycles" => 1, "cycle" => 2}},
            state} =
             PortTransport.request(
               request(2, "tick", %{"clock" => "clk", "cycles" => 1}),
               state,
               @request_timeout
             )

    assert {:ok, %{"op" => "cycle", "body" => %{"cycles" => 2, "cycle" => 4}}, state} =
             PortTransport.request(request(3, "cycle", %{"cycles" => 2}), state, @request_timeout)

    assert {:ok,
            %{
              "op" => "peek",
              "body" => %{"signal" => "count", "value" => %{"bits" => "0011", "width" => 4}}
            }, state} =
             PortTransport.request(
               request(4, "peek", %{"signal" => "count"}),
               state,
               @request_timeout
             )

    assert {:ok, %{"op" => "finish?", "body" => %{"finished" => false, "cycle" => 4}}, state} =
             PortTransport.request(request(5, "finish?", %{}), state, @request_timeout)

    assert {:ok, %{"op" => "stop", "body" => %{"status" => "closing"}}, _state} =
             PortTransport.request(request(6, "stop", %{}), state, @request_timeout)

    trace = read_trace(trace)
    assert_frame_lengths!(trace)

    assert trace |> Enum.filter(&(&1["dir"] == "in")) |> Enum.map(& &1["payload"]["op"]) ==
             ["reset", "poke", "tick", "cycle", "peek", "finish?", "stop"]
  end

  test "raw port transport accepts eval and transaction MVP operations" do
    trace = trace_path()
    {:ok, state} = PortTransport.open(executable: fixture_executable(), args: ["--trace", trace])

    on_exit(fn -> PortTransport.close(state) end)

    assert {:ok, %{"op" => "reset", "body" => %{"cycle" => 1}}, state} =
             PortTransport.request(request(0, "reset", %{"cycles" => 1}), state, @request_timeout)

    assert {:ok, %{"op" => "poke", "body" => %{"signal" => "enable"}}, state} =
             PortTransport.request(
               request(1, "poke", %{
                 "signal" => "enable",
                 "value" => %{"bits" => "1", "width" => 1}
               }),
               state,
               @request_timeout
             )

    assert {:ok, %{"op" => "eval", "body" => %{"settled" => true, "cycle" => 1}}, state} =
             PortTransport.request(request(2, "eval", %{}), state, @request_timeout)

    transaction = %{
      "steps" => [
        %{
          "op" => "poke",
          "body" => %{
            "signal" => "enable",
            "value" => %{"bits" => "1", "width" => 1}
          }
        },
        %{"op" => "tick", "body" => %{"clock" => "clk", "cycles" => 2}},
        %{"op" => "eval", "body" => %{}},
        %{"op" => "peek", "body" => %{"signal" => "count"}}
      ]
    }

    assert {:ok,
            %{
              "op" => "transaction",
              "body" => %{
                "cycle" => 3,
                "results" => [
                  %{"op" => "poke", "body" => %{"signal" => "enable", "cycle" => 1}},
                  %{"op" => "tick", "body" => %{"clock" => "clk", "cycles" => 2, "cycle" => 3}},
                  %{"op" => "eval", "body" => %{"settled" => true, "cycle" => 3}},
                  %{
                    "op" => "peek",
                    "body" => %{"signal" => "count", "value" => %{"bits" => "0010", "width" => 4}, "cycle" => 3}
                  }
                ]
              }
            }, state} =
             PortTransport.request(request(3, "transaction", transaction), state, @request_timeout)

    assert {:ok, %{"op" => "stop", "body" => %{"status" => "closing"}}, _state} =
             PortTransport.request(request(4, "stop", %{}), state, @request_timeout)

    trace = read_trace(trace)
    assert_frame_lengths!(trace)

    assert trace |> Enum.filter(&(&1["dir"] == "in")) |> Enum.map(& &1["payload"]["op"]) ==
             ["reset", "poke", "eval", "transaction", "stop"]
  end

  test "counter can be reset, advanced, and queried in one process" do
    trace = trace_path()
    {:ok, sim} = start_sim(trace)

    on_exit(fn ->
      if Process.alive?(sim) do
        SvPortSim.stop(sim)
      end
    end)

    assert {:ok, _} = SvPortSim.poke(sim, "enable", %{bits: "1", width: 1})
    assert {:ok, _} = SvPortSim.tick(sim, cycles: 3)

    assert {:ok, %{"value" => %{"bits" => before_reset}}} =
             SvPortSim.peek(sim, "count")

    assert before_reset != "0000"

    assert {:ok, %{"reset" => "rst_n", "clock" => "clk", "cycles" => 2, "final" => 1}} =
             SvPortSim.reset(sim, cycles: 2, reset: "rst_n", clock: "clk")

    assert {:ok, %{"value" => %{"bits" => "0000"}}} =
             SvPortSim.peek(sim, "count")

    assert {:ok, _} = SvPortSim.tick(sim, cycles: 1)

    assert {:ok, %{"value" => %{"bits" => after_tick}}} =
             SvPortSim.peek(sim, "count")

    assert after_tick != "0000"

    assert :ok = SvPortSim.stop(sim)
  end

  defp start_sim(trace) do
    SvPortSim.start_link(
      executable: fixture_executable(),
      args: ["--trace", trace],
      default_timeout: @request_timeout
    )
  end

  defp request(id, op, body) do
    %{
      "v" => SvPortSim.Protocol.version(),
      "id" => id,
      "kind" => "request",
      "op" => op,
      "body" => body
    }
  end

  defp fixture_executable do
    Path.expand("../../fixtures/fake_protocol_sim", __DIR__)
  end

  defp trace_path do
    path =
      Path.join(
        System.tmp_dir!(),
        "sv_port_sim_fake_#{System.unique_integer([:positive, :monotonic])}.jsonl"
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
