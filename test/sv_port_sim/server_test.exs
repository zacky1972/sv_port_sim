defmodule SvPortSim.ServerTest.RecordingTransport do
  @moduledoc false

  @behaviour SvPortSim.Transport

  alias SvPortSim.Protocol

  def open(opts) do
    notify = Keyword.fetch!(opts, :notify)

    send(notify, {:transport_opened, opts})

    {:ok,
     %{
       notify: notify,
       shutdown_mode: Keyword.get(opts, :shutdown, :ok),
       shutdown_attempts: 0
     }}
  end

  def request(%{"op" => "nonfatal"} = request, state, timeout) do
    notify_request(state, request, timeout)

    {:ok,
     error_response(
       request,
       "invalid_signal",
       "unknown signal",
       %{"signal" => "missing"}
     ), state}
  end

  def request(%{"op" => "fatal"} = request, state, timeout) do
    notify_request(state, request, timeout)

    {:ok,
     error_response(
       request,
       "timeout",
       "simulator response timed out",
       %{"op" => "fatal"}
     ), state}
  end

  def request(%{"op" => "mismatched_id"} = request, state, timeout) do
    notify_request(state, request, timeout)

    response =
      request
      |> response(request["body"])
      |> Map.put("id", request["id"] + 1)

    {:ok, response, state}
  end

  def request(%{"op" => "mismatched_op"} = request, state, timeout) do
    notify_request(state, request, timeout)

    response =
      request
      |> response(request["body"])
      |> Map.put("op", "different_op")

    {:ok, response, state}
  end

  def request(%{"op" => "shutdown"} = request, state, timeout) do
    notify_request(state, request, timeout)
    shutdown_response(request, state)
  end

  def request(request, state, timeout) do
    notify_request(state, request, timeout)
    {:ok, response(request, request["body"]), state}
  end

  def close(state) do
    send(state.notify, {:transport_closed, self()})
    :ok
  end

  defp shutdown_response(request, %{shutdown_mode: :ok} = state) do
    {:ok, response(request, %{}), state}
  end

  defp shutdown_response(
         request,
         %{shutdown_mode: :nonfatal_once, shutdown_attempts: 0} = state
       ) do
    {:ok,
     error_response(
       request,
       "invalid_state",
       "wrapper is busy",
       %{}
     ), %{state | shutdown_attempts: 1}}
  end

  defp shutdown_response(
         request,
         %{shutdown_mode: :nonfatal_once, shutdown_attempts: _attempts} = state
       ) do
    {:ok, response(request, %{}), state}
  end

  defp shutdown_response(request, %{shutdown_mode: :fatal} = state) do
    {:ok,
     error_response(
       request,
       "timeout",
       "simulator response timed out",
       %{"op" => "shutdown"}
     ), state}
  end

  defp notify_request(state, request, timeout) do
    send(state.notify, {:transport_request, request, timeout})
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

defmodule SvPortSim.ServerTest.BadOpenTransport do
  @moduledoc false

  @behaviour SvPortSim.Transport

  def open(_opts), do: :bad_open_return
  def request(_request, state, _timeout), do: {:ok, %{}, state}
  def close(_state), do: :ok
end

defmodule SvPortSim.ServerTest.BlockingTransport do
  @moduledoc false
  @behaviour SvPortSim.Transport

  alias SvPortSim.Protocol

  def open(opts) do
    notify = Keyword.fetch!(opts, :notify)
    send(notify, {:blocking_transport_opened, opts})
    {:ok, %{notify: notify}}
  end

  def request(request, state, timeout) do
    send(state.notify, {:blocking_transport_request, self(), request, timeout})

    request_id = request["id"]

    receive do
      {:release_request, ^request_id} ->
        {:ok, response(request, request["body"]), state}
    after
      wait_timeout(timeout) ->
        {:error, timeout_error(request, timeout), state}
    end
  end

  def close(state) do
    send(state.notify, {:blocking_transport_closed, self()})
    :ok
  end

  defp wait_timeout(:infinity), do: 30_000
  defp wait_timeout(timeout) when is_integer(timeout), do: timeout

  defp response(request, body) do
    %{
      "v" => Protocol.version(),
      "id" => request["id"],
      "kind" => "response",
      "op" => request["op"],
      "body" => body
    }
  end

  defp timeout_error(request, timeout) do
    {:ok, body} =
      Protocol.error_body("timeout", "blocked test request timed out", %{
        "id" => request["id"],
        "op" => request["op"],
        "timeout_ms" => inspect(timeout)
      })

    body
  end
end

defmodule SvPortSim.ServerTest do
  use ExUnit.Case, async: true

  alias SvPortSim.Protocol
  alias SvPortSim.Server
  alias SvPortSim.ServerTest.BadOpenTransport
  alias SvPortSim.ServerTest.RecordingTransport

  describe "start_link/1" do
    test "splits GenServer options from transport options and opens the transport" do
      name = unique_name()

      {:ok, pid} =
        Server.start_link(
          transport: RecordingTransport,
          name: name,
          default_timeout: 321,
          executable: "sim-wrapper",
          args: ["--seed", "1"],
          transport_opts: [
            notify: self(),
            custom: :value
          ]
        )

      assert Process.whereis(name) == pid

      assert_receive {:transport_opened, opts}

      assert Keyword.fetch!(opts, :notify) == self()
      assert Keyword.fetch!(opts, :custom) == :value
      assert Keyword.fetch!(opts, :executable) == "sim-wrapper"
      assert Keyword.fetch!(opts, :args) == ["--seed", "1"]
      assert Keyword.fetch!(opts, :transport) == RecordingTransport

      refute Keyword.has_key?(opts, :name)
      refute Keyword.has_key?(opts, :default_timeout)
      refute Keyword.has_key?(opts, :transport_opts)

      ref = Process.monitor(pid)

      assert :ok = Server.stop(name, :default)

      assert_receive {:transport_request,
                      %{
                        "id" => 0,
                        "kind" => "request",
                        "op" => "shutdown",
                        "body" => %{}
                      }, 321}

      assert_receive {:transport_closed, _pid}
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end

    test "returns default transport validation errors before starting a process" do
      assert {:error, {:missing_required_option, :executable}} =
               Server.start_link([])
    end

    test "normalizes bad transport open returns into start errors" do
      previous_trap_exit = Process.flag(:trap_exit, true)

      try do
        assert {:error, {:bad_transport_return, :bad_open_return}} =
                 Server.start_link(transport: BadOpenTransport)
      after
        Process.flag(:trap_exit, previous_trap_exit)
      end
    end
  end

  describe "request/4" do
    test "wraps all MVP simulator operations as state-independent request envelopes" do
      version = Protocol.version()

      operations = [
        {"reset", %{"cycles" => 2, "reset" => "rst_n", "clock" => "clk"}},
        {"poke", %{"signal" => "enable", "value" => %{"bits" => "1", "width" => 1}}},
        {"peek", %{"signal" => "count"}},
        {"eval", %{}},
        {"tick", %{"cycles" => 3, "clock" => "clk"}},
        {"cycle", %{"cycles" => 4, "clock" => "clk"}},
        {"transaction",
         %{
           "steps" => [
             %{
               "op" => "poke",
               "body" => %{
                 "signal" => "enable",
                 "value" => %{"bits" => "1", "width" => 1}
               }
             },
             %{"op" => "eval", "body" => %{}},
             %{"op" => "peek", "body" => %{"signal" => "count"}}
           ]
         }}
      ]

      {:ok, sim} =
        start_server(
          default_timeout: 321,
          transport_opts: [notify: self()]
        )

      assert_receive {:transport_opened, _opts}

      for {{op, body}, id} <- Enum.with_index(operations) do
        assert {:ok, ^body} = Server.request(sim, op, body, :default)

        assert_receive {:transport_request, request, 321}

        assert request == %{
                 "v" => version,
                 "id" => id,
                 "kind" => "request",
                 "op" => op,
                 "body" => body
               }
      end

      ref = Process.monitor(sim)

      assert :ok = Server.stop(sim, :default)

      assert_receive {:transport_request, shutdown_request, 321}

      assert shutdown_request == %{
               "v" => version,
               "id" => length(operations),
               "kind" => "request",
               "op" => "shutdown",
               "body" => %{}
             }

      assert_receive {:transport_closed, _pid}
      assert_receive {:DOWN, ^ref, :process, ^sim, :normal}
    end

    test "assigns monotonic request ids and resolves default and per-call timeouts" do
      version = Protocol.version()

      {:ok, sim} =
        start_server(
          default_timeout: 123,
          transport_opts: [notify: self()]
        )

      assert {:ok, %{"cycles" => 1}} =
               Server.request(sim, "tick", %{"cycles" => 1}, :default)

      assert_receive {:transport_request,
                      %{
                        "v" => ^version,
                        "id" => 0,
                        "kind" => "request",
                        "op" => "tick",
                        "body" => %{"cycles" => 1}
                      }, 123}

      assert {:ok, %{"signal" => "enable"}} =
               Server.request(sim, "poke", %{"signal" => "enable"}, 456)

      assert_receive {:transport_request,
                      %{
                        "v" => ^version,
                        "id" => 1,
                        "kind" => "request",
                        "op" => "poke",
                        "body" => %{"signal" => "enable"}
                      }, 456}

      ref = Process.monitor(sim)

      assert :ok = Server.stop(sim, 789)

      assert_receive {:transport_request,
                      %{
                        "v" => ^version,
                        "id" => 2,
                        "kind" => "request",
                        "op" => "shutdown",
                        "body" => %{}
                      }, 789}

      assert_receive {:transport_closed, _pid}
      assert_receive {:DOWN, ^ref, :process, ^sim, :normal}
    end

    test "returns non-fatal wrapper errors and keeps the instance alive" do
      {:ok, sim} = start_server(transport_opts: [notify: self()])

      assert {:error,
              %{
                "code" => "invalid_signal",
                "fatal" => false,
                "details" => %{"signal" => "missing"}
              }} = Server.request(sim, "nonfatal", %{}, :default)

      assert_receive {:transport_request,
                      %{
                        "id" => 0,
                        "kind" => "request",
                        "op" => "nonfatal"
                      }, 5_000}

      assert Process.alive?(sim)
      refute_receive {:transport_closed, _pid}, 50

      ref = Process.monitor(sim)

      assert :ok = Server.stop(sim, :default)

      assert_receive {:transport_request,
                      %{
                        "id" => 1,
                        "kind" => "request",
                        "op" => "shutdown"
                      }, 5_000}

      assert_receive {:transport_closed, _pid}
      assert_receive {:DOWN, ^ref, :process, ^sim, :normal}
    end

    test "returns fatal wrapper errors, closes the transport once, and stops" do
      {:ok, sim} = start_server(transport_opts: [notify: self()])
      ref = Process.monitor(sim)

      assert {:error, %{"code" => "timeout", "fatal" => true}} =
               Server.request(sim, "fatal", %{}, :default)

      assert_receive {:transport_request,
                      %{
                        "id" => 0,
                        "kind" => "request",
                        "op" => "fatal"
                      }, 5_000}

      assert_receive {:transport_closed, _pid}
      assert_receive {:DOWN, ^ref, :process, ^sim, :normal}
      refute_receive {:transport_closed, _pid}, 50
    end

    test "treats mismatched response ids as fatal malformed_output errors" do
      {:ok, sim} = start_server(transport_opts: [notify: self()])
      ref = Process.monitor(sim)

      assert {:error, %{"code" => "malformed_output", "fatal" => true}} =
               Server.request(sim, "mismatched_id", %{}, :default)

      assert_receive {:transport_request,
                      %{
                        "id" => 0,
                        "kind" => "request",
                        "op" => "mismatched_id"
                      }, 5_000}

      assert_receive {:transport_closed, _pid}
      assert_receive {:DOWN, ^ref, :process, ^sim, :normal}
    end

    test "treats mismatched response ops as fatal malformed_output errors" do
      {:ok, sim} = start_server(transport_opts: [notify: self()])
      ref = Process.monitor(sim)

      assert {:error, %{"code" => "malformed_output", "fatal" => true}} =
               Server.request(sim, "mismatched_op", %{}, :default)

      assert_receive {:transport_request,
                      %{
                        "id" => 0,
                        "kind" => "request",
                        "op" => "mismatched_op"
                      }, 5_000}

      assert_receive {:transport_closed, _pid}
      assert_receive {:DOWN, ^ref, :process, ^sim, :normal}
    end

    test "calling a stopped instance returns canonical port_closed error" do
      {:ok, sim} = start_server(transport_opts: [notify: self()])
      ref = Process.monitor(sim)

      assert :ok = Server.stop(sim, :default)

      assert_receive {:transport_request,
                      %{
                        "id" => 0,
                        "kind" => "request",
                        "op" => "shutdown"
                      }, 5_000}

      assert_receive {:transport_closed, _pid}
      assert_receive {:DOWN, ^ref, :process, ^sim, :normal}

      assert {:error,
              %{
                "code" => "port_closed",
                "fatal" => true
              }} = Server.request(sim, "tick", %{"cycles" => 1}, :default)
    end
  end

  describe "stop/2" do
    test "successful shutdown closes the transport and stops the instance" do
      {:ok, sim} =
        start_server(
          default_timeout: 234,
          transport_opts: [notify: self()]
        )

      ref = Process.monitor(sim)

      assert :ok = Server.stop(sim, :default)

      assert_receive {:transport_request,
                      %{
                        "id" => 0,
                        "kind" => "request",
                        "op" => "shutdown",
                        "body" => %{}
                      }, 234}

      assert_receive {:transport_closed, _pid}
      assert_receive {:DOWN, ^ref, :process, ^sim, :normal}
    end

    test "non-fatal shutdown errors keep the instance alive and preserve state" do
      {:ok, sim} =
        start_server(
          transport_opts: [
            notify: self(),
            shutdown: :nonfatal_once
          ]
        )

      assert {:error, %{"code" => "invalid_state", "fatal" => false}} =
               Server.stop(sim, :default)

      assert_receive {:transport_request,
                      %{
                        "id" => 0,
                        "kind" => "request",
                        "op" => "shutdown"
                      }, 5_000}

      assert Process.alive?(sim)
      refute_receive {:transport_closed, _pid}, 50

      ref = Process.monitor(sim)

      assert :ok = Server.stop(sim, :default)

      assert_receive {:transport_request,
                      %{
                        "id" => 1,
                        "kind" => "request",
                        "op" => "shutdown"
                      }, 5_000}

      assert_receive {:transport_closed, _pid}
      assert_receive {:DOWN, ^ref, :process, ^sim, :normal}
    end

    test "fatal shutdown errors close the transport once and stop the instance" do
      {:ok, sim} =
        start_server(
          transport_opts: [
            notify: self(),
            shutdown: :fatal
          ]
        )

      ref = Process.monitor(sim)

      assert {:error, %{"code" => "timeout", "fatal" => true}} =
               Server.stop(sim, :default)

      assert_receive {:transport_request,
                      %{
                        "id" => 0,
                        "kind" => "request",
                        "op" => "shutdown"
                      }, 5_000}

      assert_receive {:transport_closed, _pid}
      assert_receive {:DOWN, ^ref, :process, ^sim, :normal}
      refute_receive {:transport_closed, _pid}, 50
    end
  end

  describe "instance state acceptance for issue #71" do
    test "records simulator metadata, timeout, transport handle, and lifecycle state" do
      signal_spec = SvPortSim.SignalSpec.example_specs()

      {:ok, sim} =
        start_server(
          default_timeout: 987,
          executable: "sim-wrapper",
          args: ["--seed", "1"],
          signal_spec: signal_spec,
          transport_opts: [notify: self()]
        )

      assert_receive {:transport_opened, opts}
      assert Keyword.fetch!(opts, :executable) == "sim-wrapper"
      assert Keyword.fetch!(opts, :args) == ["--seed", "1"]

      state = :sys.get_state(sim)

      assert state_field(state, [:transport, :transport_module]) == RecordingTransport
      assert state_field(state, [:transport_state, :port, :port_handle]) != nil
      assert state_field(state, [:default_timeout, :timeout, :timeout_ms]) == 987

      assert state_field(state, :executable) == "sim-wrapper"
      assert state_field(state, :signal_spec) == signal_spec
      assert state_field(state, :pending_request) in [nil, false, :none]
      assert simulation_progress(state) == 0

      refute lifecycle_status(state) in [:closed, :crashed, :stopped, :unhealthy]

      ref = Process.monitor(sim)
      assert :ok = Server.stop(sim, :default)
      assert_receive {:transport_request, %{"op" => "shutdown"}, 987}
      assert_receive {:transport_closed, _pid}
      assert_receive {:DOWN, ^ref, :process, ^sim, :normal}
    end

    test "updates simulation time or cycle count after tick and cycle operations" do
      {:ok, sim} = start_server(transport_opts: [notify: self()])
      assert_receive {:transport_opened, _opts}

      assert simulation_progress(:sys.get_state(sim)) == 0

      assert {:ok, %{"cycles" => 3}} =
               Server.request(sim, "tick", %{"cycles" => 3}, :default)

      assert_receive {:transport_request, %{"id" => 0, "op" => "tick"}, 5_000}
      assert simulation_progress(:sys.get_state(sim)) == 3

      assert {:ok, %{"cycles" => 4}} =
               Server.request(sim, "cycle", %{"cycles" => 4}, :default)

      assert_receive {:transport_request, %{"id" => 1, "op" => "cycle"}, 5_000}
      assert simulation_progress(:sys.get_state(sim)) == 7

      ref = Process.monitor(sim)
      assert :ok = Server.stop(sim, :default)
      assert_receive {:transport_request, %{"id" => 2, "op" => "shutdown"}, 5_000}
      assert_receive {:transport_closed, _pid}
      assert_receive {:DOWN, ^ref, :process, ^sim, :normal}
    end

    test "records pending request state and rejects overlapping synchronous calls as busy" do
      {:ok, sim} =
        start_server(
          transport: SvPortSim.ServerTest.BlockingTransport,
          transport_opts: [notify: self()]
        )

      assert_receive {:blocking_transport_opened, _opts}

      first_request =
        Task.async(fn -> Server.request(sim, "tick", %{"cycles" => 1}, :default) end)

      assert_receive {:blocking_transport_request, transport_pid, %{"id" => 0, "op" => "tick"},
                      5_000}

      try do
        state = get_state_or_flunk(sim, 50)
        pending_request = state_field(state, :pending_request)

        assert pending_request not in [nil, false, :none]
        assert pending_request_value(pending_request, :id) == 0
        assert pending_request_value(pending_request, :op) == "tick"

        assert {:error, %{"code" => code, "fatal" => false}} =
                 Server.request(sim, "peek", %{"signal" => "count"}, 25)

        assert code in ["invalid_state", "busy"]

        refute_receive {:blocking_transport_request, _pid, %{"op" => "peek"}, _timeout}, 50
      after
        send(transport_pid, {:release_request, 0})

        case Task.yield(first_request, 500) || Task.shutdown(first_request, :brutal_kill) do
          {:ok, _result} -> :ok
          nil -> :ok
        end

        if Process.alive?(sim) do
          stop_blocking_server(sim)
        end
      end
    end

    test "fatal simulator errors close the transport and do not leave a healthy live instance" do
      {:ok, sim} = start_server(transport_opts: [notify: self()])
      assert_receive {:transport_opened, _opts}

      refute lifecycle_status(:sys.get_state(sim)) in [:closed, :crashed, :stopped, :unhealthy]

      ref = Process.monitor(sim)

      assert {:error, %{"code" => "timeout", "fatal" => true}} =
               Server.request(sim, "fatal", %{}, :default)

      assert_receive {:transport_request, %{"id" => 0, "op" => "fatal"}, 5_000}
      assert_receive {:transport_closed, _pid}
      assert_receive {:DOWN, ^ref, :process, ^sim, :normal}

      refute Process.alive?(sim)

      assert {:error, %{"code" => "port_closed", "fatal" => true}} =
               Server.request(sim, "tick", %{"cycles" => 1}, :default)
    end
  end

  defp simulation_progress(state) do
    state_field(state, [:cycle_count, :simulation_time, :time])
  end

  defp lifecycle_status(state) do
    state_field(state, [:status, :lifecycle_status, :health, :simulator_status])
  end

  defp state_field(state, field) when is_atom(field), do: state_field(state, [field])

  defp state_field(%{} = state, fields) when is_list(fields) do
    case fetch_any(state, fields) do
      {:ok, value} ->
        value

      :error ->
        flunk(
          "expected instance state to include one of #{inspect(fields)}, got keys: #{inspect(state_keys(state))}"
        )
    end
  end

  defp pending_request_value(pending_request, field) when is_atom(field) do
    field_names = [field, Atom.to_string(field)]

    with :error <- fetch_any(pending_request, field_names),
         {:ok, nested_request} <-
           fetch_any(pending_request, [:request, "request", :envelope, "envelope"]) do
      fetch_any(nested_request, field_names)
    end
    |> case do
      {:ok, value} ->
        value

      :error ->
        flunk(
          "expected pending request to expose #{inspect(field)}, got: #{inspect(pending_request)}"
        )
    end
  end

  defp fetch_any(%{} = map, fields) do
    case Enum.find(fields, &Map.has_key?(map, &1)) do
      nil -> :error
      field -> Map.fetch(map, field)
    end
  end

  defp fetch_any(_value, _fields), do: :error

  defp state_keys(%{} = state) do
    state
    |> Map.keys()
    |> Enum.reject(&(&1 == :__struct__))
  end

  defp get_state_or_flunk(pid, timeout) do
    :sys.get_state(pid, timeout)
  catch
    :exit, reason ->
      flunk(
        "expected instance state to be observable while a request is pending, got #{inspect(reason)}"
      )
  end

  defp stop_blocking_server(sim) do
    stop_task = Task.async(fn -> Server.stop(sim, :default) end)

    receive do
      {:blocking_transport_request, transport_pid, %{"op" => "shutdown"} = request, _timeout} ->
        send(transport_pid, {:release_request, request["id"]})
    after
      100 ->
        :ok
    end

    case Task.yield(stop_task, 500) || Task.shutdown(stop_task, :brutal_kill) do
      {:ok, _result} -> :ok
      nil -> Process.exit(sim, :kill)
    end
  end

  defp start_server(opts) do
    opts =
      Keyword.merge(
        [
          transport: RecordingTransport
        ],
        opts
      )

    Server.start_link(opts)
  end

  defp unique_name do
    :"#{__MODULE__}.#{System.unique_integer([:positive])}"
  end
end
