defmodule SvPortSim.Server do
  @moduledoc """
  Internal `GenServer` implementation for a single Verilated simulator instance.

  `SvPortSim.Server` owns one simulator transport worker. The server keeps the
  observable instance state, assigns request IDs, serializes protocol requests,
  validates response envelopes, and closes the transport when the instance
  terminates.
  """

  use GenServer

  alias SvPortSim.Protocol

  @default_timeout 5_000
  @default_transport SvPortSim.Transport.Port
  @gen_server_options [:debug, :hibernate_after, :name, :spawn_opt, :timeout]

  defstruct transport: @default_transport,
            transport_worker: nil,
            transport_worker_ref: nil,
            transport_state: nil,
            executable: nil,
            args: [],
            signal_spec: nil,
            default_timeout: @default_timeout,
            cycle_count: 0,
            pending_request: nil,
            status: :running,
            next_id: 0,
            closed?: false

  @type instance :: GenServer.server()
  @type request_body :: %{required(String.t()) => term()}
  @type response_body :: %{required(String.t()) => term()}
  @type error_body :: %{required(String.t()) => term()}
  @type timeout_override :: :default | timeout()

  @doc """
  Starts one simulator server and links it to the caller.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts), do: do_start(:start_link, opts)
  def start_link(opts), do: {:error, {:invalid_options, opts}}

  @doc """
  Starts one simulator server without linking it to the caller.
  """
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts) when is_list(opts), do: do_start(:start, opts)
  def start(opts), do: {:error, {:invalid_options, opts}}

  @doc """
  Sends one already-normalized runtime operation to the simulator transport.
  """
  @spec request(instance(), String.t(), request_body(), timeout_override()) ::
          {:ok, response_body()} | {:error, error_body()}
  def request(instance, op, body, timeout_override) do
    GenServer.call(
      instance,
      {:request, op, body, timeout_override},
      call_timeout(timeout_override)
    )
  catch
    :exit, {:timeout, _details} ->
      runtime_failure({:timeout, "unknown", op, timeout_override})

    :exit, {:noproc, _details} ->
      runtime_failure(:port_closed, %{"reason" => "simulation instance is not running"})

    :exit, reason ->
      runtime_failure({:simulator_failure, reason})
  end

  @doc """
  Sends the terminal `"shutdown"` operation and stops the simulator server.
  """
  @spec stop(instance(), timeout_override()) :: :ok | {:error, error_body()}
  def stop(instance, timeout_override) do
    {monitored_pid, monitor_ref} = monitor_instance(instance)

    result =
      try do
        GenServer.call(instance, {:stop, timeout_override}, call_timeout(timeout_override))
      catch
        :exit, {:timeout, _details} ->
          runtime_failure({:timeout, "stop", "shutdown", timeout_override})

        :exit, {:noproc, _details} ->
          runtime_failure(:port_closed, %{"reason" => "simulation instance is not running"})

        :exit, reason ->
          runtime_failure({:simulator_failure, reason})
      end

    wait_for_terminal_stop(result, monitored_pid, monitor_ref)
  end

  @impl true
  def init(opts) do
    with {:ok, config} <- normalize_start_options(opts),
         {:ok, worker, worker_ref, transport_state} <-
           open_transport(config.transport, config.transport_opts) do
      {:ok,
       %__MODULE__{
         transport: config.transport,
         transport_worker: worker,
         transport_worker_ref: worker_ref,
         transport_state: transport_state,
         executable: config.executable,
         args: config.args,
         signal_spec: config.signal_spec,
         default_timeout: config.default_timeout,
         cycle_count: 0,
         pending_request: nil,
         status: :running
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:request, op, _body, _timeout_override}, _from, %{closed?: true} = state) do
    {:reply, runtime_failure(:port_closed, %{"op" => op}), state}
  end

  def handle_call(
        {:request, op, _body, _timeout_override},
        _from,
        %{pending_request: pending} = state
      )
      when not is_nil(pending) do
    {:reply, busy_result(op, pending), state}
  end

  def handle_call({:request, op, body, timeout_override}, from, state) do
    id = state.next_id
    timeout = effective_timeout(timeout_override, state.default_timeout)
    request = request_envelope(id, op, body)
    request_ref = make_ref()

    pending = %{
      kind: :request,
      from: from,
      ref: request_ref,
      id: id,
      op: op,
      request: request,
      timeout: timeout
    }

    send_transport_request(state, request_ref, request, timeout)

    {:noreply, %{state | next_id: id + 1, pending_request: pending, status: :busy}}
  end

  def handle_call({:stop, _timeout_override}, _from, %{closed?: true} = state) do
    {:reply, runtime_failure(:port_closed, %{"op" => "shutdown"}), state}
  end

  def handle_call({:stop, _timeout_override}, _from, %{pending_request: pending} = state)
      when not is_nil(pending) do
    {:reply, busy_result("shutdown", pending), state}
  end

  def handle_call({:stop, timeout_override}, from, state) do
    timeout = effective_timeout(timeout_override, state.default_timeout)
    request = request_envelope(state.next_id, "shutdown", %{})
    request_ref = make_ref()

    pending = %{
      kind: :stop,
      from: from,
      ref: request_ref,
      id: state.next_id,
      op: "shutdown",
      request: request,
      timeout: timeout
    }

    send_transport_request(state, request_ref, request, timeout)

    {:noreply, %{state | next_id: state.next_id + 1, pending_request: pending, status: :busy}}
  end

  @impl true
  def handle_info({:transport_response, request_ref, raw_result}, state) do
    case state.pending_request do
      %{ref: ^request_ref, kind: :request} = pending ->
        complete_runtime_request(raw_result, pending, state)

      %{ref: ^request_ref, kind: :stop} = pending ->
        complete_stop_request(raw_result, pending, state)

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{transport_worker_ref: ref} = state) do
    pending = state.pending_request

    error_body =
      runtime_error(
        {:transport_worker_down, reason},
        pending_request_or_unknown(pending),
        pending_timeout_or_unknown(pending)
      )

    state = %{
      state
      | transport_worker: nil,
        transport_worker_ref: nil,
        pending_request: nil,
        closed?: true,
        status: :crashed
    }

    reply_pending(pending, {:error, error_body})

    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _state = close_transport(state)
    :ok
  end

  defp do_start(kind, opts) do
    if Keyword.keyword?(opts) do
      {server_opts, init_opts} = Keyword.split(opts, @gen_server_options)

      with {:ok, _config} <- normalize_start_options(init_opts) do
        apply(GenServer, kind, [__MODULE__, init_opts, server_opts])
      end
    else
      {:error, {:invalid_options, opts}}
    end
  end

  defp normalize_start_options(opts) do
    transport = Keyword.get(opts, :transport, @default_transport)
    default_timeout = Keyword.get(opts, :default_timeout, @default_timeout)
    transport_opts = transport_opts(opts, transport)

    with {:ok, default_timeout} <- normalize_default_timeout(default_timeout),
         :ok <- validate_transport(transport),
         :ok <- validate_transport_opts(transport_opts),
         :ok <- validate_default_transport_options(transport, transport_opts) do
      {:ok,
       %{
         transport: transport,
         transport_opts: transport_opts,
         executable: Keyword.get(transport_opts, :executable),
         args: Keyword.get(transport_opts, :args, []),
         signal_spec: Keyword.get(transport_opts, :signal_spec),
         default_timeout: default_timeout
       }}
    end
  end

  defp transport_opts(opts, transport) do
    base_opts =
      Keyword.drop(
        opts,
        @gen_server_options ++ [:transport, :default_timeout, :transport_opts, :id]
      )

    extra_opts = Keyword.get(opts, :transport_opts, [])

    if Keyword.keyword?(extra_opts) do
      base_opts
      |> Keyword.merge(extra_opts)
      |> Keyword.put_new(:transport, transport)
    else
      extra_opts
    end
  end

  defp validate_transport(transport) when is_atom(transport), do: :ok
  defp validate_transport(transport), do: {:error, {:invalid_transport, transport}}

  defp validate_transport_opts(opts) do
    if Keyword.keyword?(opts) do
      :ok
    else
      {:error, {:invalid_transport_opts, opts}}
    end
  end

  defp validate_default_transport_options(@default_transport, opts) do
    if Keyword.get(opts, :executable) in [nil, ""] do
      {:error, {:missing_required_option, :executable}}
    else
      :ok
    end
  end

  defp validate_default_transport_options(_transport, _opts), do: :ok

  defp normalize_default_timeout(timeout) do
    case Protocol.normalize_timeout(timeout) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp call_timeout(:default), do: :infinity
  defp call_timeout(timeout), do: timeout

  defp effective_timeout(:default, default_timeout), do: default_timeout
  defp effective_timeout(timeout, _default_timeout), do: timeout

  defp request_envelope(id, op, body) do
    %{
      "v" => Protocol.version(),
      "id" => id,
      "kind" => "request",
      "op" => op,
      "body" => body
    }
  end

  defp open_transport(transport, opts) do
    parent = self()
    open_ref = make_ref()

    worker =
      spawn_link(fn ->
        transport_worker_open(parent, open_ref, transport, opts)
      end)

    receive do
      {:transport_worker_opened, ^open_ref, {:ok, transport_state}} ->
        worker_ref = Process.monitor(worker)
        {:ok, worker, worker_ref, transport_state}

      {:transport_worker_opened, ^open_ref, {:error, reason}} ->
        {:error, reason}
    after
      @default_timeout ->
        Process.unlink(worker)
        Process.exit(worker, :kill)
        {:error, {:transport_open_timeout, @default_timeout}}
    end
  end

  defp send_transport_request(%{transport_worker: nil}, _request_ref, _request, _timeout), do: :ok

  defp send_transport_request(%{transport_worker: worker}, request_ref, request, timeout) do
    send(worker, {:transport_request, self(), request_ref, request, timeout})
    :ok
  end

  defp transport_worker_open(parent, open_ref, transport, opts) do
    case safe_transport_call(fn -> transport.open(opts) end) do
      {:ok, transport_state} ->
        send(parent, {:transport_worker_opened, open_ref, {:ok, transport_state}})
        transport_worker_loop(transport, transport_state)

      {:error, reason} ->
        send(parent, {:transport_worker_opened, open_ref, {:error, reason}})

      other ->
        send(
          parent,
          {:transport_worker_opened, open_ref, {:error, {:bad_transport_return, other}}}
        )
    end
  end

  defp transport_worker_loop(transport, transport_state) do
    receive do
      {:transport_request, owner, request_ref, request, timeout} ->
        raw_result =
          safe_transport_call(fn -> transport.request(request, transport_state, timeout) end)

        send(owner, {:transport_response, request_ref, raw_result})
        transport_worker_loop(transport, next_transport_state(raw_result, transport_state))

      {:transport_close, owner, close_ref} ->
        close_result = safe_transport_call(fn -> transport.close(transport_state) end)
        send(owner, {:transport_closed, close_ref, close_result})
        :ok
    end
  end

  defp next_transport_state({:ok, _response, transport_state}, _current), do: transport_state
  defp next_transport_state({:error, _error_body, transport_state}, _current), do: transport_state
  defp next_transport_state(_raw_result, current), do: current

  defp complete_runtime_request(raw_result, pending, state) do
    transport_result = transport_result(raw_result, pending.request, pending.timeout, state)

    case return_from_transport(transport_result, pending.request) do
      {:ok, body, next_state} ->
        next_state =
          next_state
          |> update_simulation_progress(pending.request)
          |> mark_request_complete(:running)

        GenServer.reply(pending.from, {:ok, body})
        {:noreply, next_state}

      {:error, error_body, next_state} ->
        if fatal_error?(error_body) do
          next_state =
            next_state
            |> mark_request_complete(:crashed)
            |> close_transport()

          GenServer.reply(pending.from, {:error, error_body})
          {:stop, :normal, next_state}
        else
          next_state = mark_request_complete(next_state, :running)
          GenServer.reply(pending.from, {:error, error_body})
          {:noreply, next_state}
        end
    end
  end

  defp complete_stop_request(raw_result, pending, state) do
    transport_result = transport_result(raw_result, pending.request, pending.timeout, state)

    case return_from_transport(transport_result, pending.request) do
      {:ok, _body, next_state} ->
        next_state =
          next_state
          |> mark_request_complete(:stopped)
          |> close_transport()

        GenServer.reply(pending.from, :ok)
        {:stop, :normal, next_state}

      {:error, error_body, next_state} ->
        if fatal_error?(error_body) do
          next_state =
            next_state
            |> mark_request_complete(:crashed)
            |> close_transport()

          GenServer.reply(pending.from, {:error, error_body})
          {:stop, :normal, next_state}
        else
          next_state = mark_request_complete(next_state, :running)
          GenServer.reply(pending.from, {:error, error_body})
          {:noreply, next_state}
        end
    end
  end

  defp transport_result(raw_result, request, timeout, state) do
    case raw_result do
      {:ok, response, transport_state} ->
        {:ok, response, %{state | transport_state: transport_state}}

      {:error, error_body, transport_state} when is_map(error_body) ->
        {:error, error_body, %{state | transport_state: transport_state}}

      {:error, reason, transport_state} ->
        {:error, runtime_error(reason, request, timeout),
         %{state | transport_state: transport_state}}

      {:error, error_body} when is_map(error_body) ->
        {:error, error_body, state}

      {:error, reason} ->
        {:error, runtime_error(reason, request, timeout), state}

      other ->
        {:error, runtime_error({:bad_transport_return, other}, request, timeout), state}
    end
  end

  defp return_from_transport(transport_result, request) do
    case transport_result do
      {:ok, response, state} ->
        with :ok <- validate_response(response, request),
             {:ok, body} <- Protocol.to_elixir_return(response) do
          {:ok, body, state}
        else
          {:error, error_body} when is_map(error_body) ->
            {:error, error_body, state}

          {:error, reason} ->
            {:error,
             runtime_error(
               reason,
               request,
               Map.get(response_or_empty(response), "timeout", :unknown)
             ), state}
        end

      {:error, error_body, state} ->
        {:error, error_body, state}
    end
  end

  defp validate_response(response, request) do
    with :ok <- Protocol.validate_envelope(response),
         :ok <- validate_response_kind(response),
         :ok <- validate_response_id(response, request),
         :ok <- validate_response_op(response, request) do
      :ok
    else
      {:error, reason} ->
        runtime_failure(:malformed_output, %{"reason" => inspect(reason)})
    end
  end

  defp validate_response_kind(%{"kind" => kind}) when kind in ["response", "error"], do: :ok
  defp validate_response_kind(%{"kind" => kind}), do: {:error, {:invalid_response_kind, kind}}

  defp validate_response_id(%{"id" => id}, %{"id" => id}), do: :ok

  defp validate_response_id(%{"id" => id}, %{"id" => expected}) do
    {:error, {:unexpected_response_id, id, expected}}
  end

  defp validate_response_op(%{"op" => op}, %{"op" => op}), do: :ok

  defp validate_response_op(%{"op" => op}, %{"op" => expected}) do
    {:error, {:unexpected_response_op, op, expected}}
  end

  defp response_or_empty(response) when is_map(response), do: response
  defp response_or_empty(_response), do: %{}

  defp update_simulation_progress(state, %{"op" => op, "body" => body})
       when op in ["tick", "cycle"] do
    cycles = Map.get(body, "cycles", 1)

    if is_integer(cycles) and cycles > 0 do
      %{state | cycle_count: state.cycle_count + cycles}
    else
      state
    end
  end

  defp update_simulation_progress(state, _request), do: state

  defp mark_request_complete(state, status) do
    %{state | pending_request: nil, status: status}
  end

  defp busy_result(op, pending) do
    runtime_failure(:invalid_state, %{
      "reason" => "another simulator request is already pending",
      "op" => op,
      "pending_id" => Map.get(pending, :id),
      "pending_op" => Map.get(pending, :op)
    })
  end

  defp pending_request_or_unknown(%{request: request}), do: request
  defp pending_request_or_unknown(_pending), do: request_envelope(0, "unknown", %{})

  defp pending_timeout_or_unknown(%{timeout: timeout}), do: timeout
  defp pending_timeout_or_unknown(_pending), do: :unknown

  defp reply_pending(%{from: from}, reply), do: GenServer.reply(from, reply)
  defp reply_pending(_pending, _reply), do: :ok

  defp runtime_error(error_body, _request, _timeout) when is_map(error_body), do: error_body

  defp runtime_error({:timeout, _id, _op, timeout} = reason, _request, timeout) do
    reason
    |> runtime_failure()
    |> unwrap_error_body()
  end

  defp runtime_error(reason, request, timeout) do
    request
    |> Map.take(["id", "op"])
    |> Map.put("timeout_ms", inspect(timeout))
    |> Map.put("reason", inspect(reason))
    |> then(&runtime_failure({:wrapper_fault, reason}, &1))
    |> unwrap_error_body()
  end

  defp runtime_failure(reason, details \\ %{}) do
    Protocol.runtime_failure(reason, details)
  end

  defp unwrap_error_body({:error, error_body}) when is_map(error_body), do: error_body

  defp unwrap_error_body({:error, reason}) do
    %{
      "code" => "wrapper_fault",
      "message" => "wrapper fault",
      "details" => %{"reason" => inspect(reason)},
      "fatal" => true
    }
  end

  defp fatal_error?(%{"fatal" => true}), do: true
  defp fatal_error?(_error_body), do: false

  defp close_transport(%{closed?: true} = state), do: state

  defp close_transport(%{transport_worker: nil} = state) do
    %{state | closed?: true, pending_request: nil, status: closed_status(state.status)}
  end

  defp close_transport(%{transport_worker: worker, transport_worker_ref: worker_ref} = state) do
    if is_reference(worker_ref) do
      Process.demonitor(worker_ref, [:flush])
    end

    close_ref = make_ref()
    send(worker, {:transport_close, self(), close_ref})

    receive do
      {:transport_closed, ^close_ref, _close_result} ->
        :ok
    after
      200 ->
        Process.exit(worker, :kill)
    end

    %{
      state
      | closed?: true,
        pending_request: nil,
        status: closed_status(state.status),
        transport_worker: nil,
        transport_worker_ref: nil
    }
  end

  defp closed_status(:stopped), do: :stopped
  defp closed_status(:crashed), do: :crashed
  defp closed_status(_status), do: :closed

  defp safe_transport_call(fun) do
    fun.()
  rescue
    exception -> {:error, {:transport_error, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:transport_error, {kind, reason}}}
  end

  defp monitor_instance(pid) when is_pid(pid), do: {pid, Process.monitor(pid)}

  defp monitor_instance(name) when is_atom(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> {pid, Process.monitor(pid)}
      nil -> {nil, nil}
    end
  end

  defp monitor_instance({:global, name}) do
    case :global.whereis_name(name) do
      pid when is_pid(pid) -> {pid, Process.monitor(pid)}
      :undefined -> {nil, nil}
    end
  end

  defp monitor_instance(_instance), do: {nil, nil}

  defp wait_for_terminal_stop(result, pid, monitor_ref) do
    if terminal_stop_result?(result) and is_pid(pid) and is_reference(monitor_ref) do
      receive do
        {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> result
      after
        1_000 -> result
      end
    else
      result
    end
  after
    if is_reference(monitor_ref) do
      Process.demonitor(monitor_ref, [:flush])
    end
  end

  defp terminal_stop_result?(:ok), do: true
  defp terminal_stop_result?({:error, %{"fatal" => true}}), do: true
  defp terminal_stop_result?(_result), do: false
end
