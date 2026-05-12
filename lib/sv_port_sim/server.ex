defmodule SvPortSim.Server do
  @moduledoc false

  use GenServer

  alias SvPortSim.Protocol

  @default_timeout 5_000
  @default_transport SvPortSim.Transport.Port
  @gen_server_options [:debug, :hibernate_after, :name, :spawn_opt, :timeout]

  defstruct transport: @default_transport,
            transport_state: nil,
            default_timeout: @default_timeout,
            next_id: 0,
            closed?: false

  @type instance :: GenServer.server()
  @type request_body :: %{required(String.t()) => term()}
  @type response_body :: %{required(String.t()) => term()}
  @type error_body :: %{required(String.t()) => term()}
  @type timeout_override :: :default | timeout()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts), do: do_start(:start_link, opts)
  def start_link(opts), do: {:error, {:invalid_options, opts}}

  @spec start(keyword()) :: GenServer.on_start()
  def start(opts) when is_list(opts), do: do_start(:start, opts)
  def start(opts), do: {:error, {:invalid_options, opts}}

  @spec request(instance(), String.t(), request_body(), timeout_override()) ::
          {:ok, response_body()} | {:error, error_body()}
  def request(instance, op, body, timeout_override) do
    try do
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
  end

  @spec stop(instance(), timeout_override()) :: :ok | {:error, error_body()}
  def stop(instance, timeout_override) do
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
  end

  @impl true
  def init(opts) do
    with {:ok, config} <- normalize_start_options(opts),
         {:ok, transport_state} <- open_transport(config.transport, config.transport_opts) do
      {:ok,
       %__MODULE__{
         transport: config.transport,
         transport_state: transport_state,
         default_timeout: config.default_timeout
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:request, op, body, timeout_override}, _from, state) do
    id = state.next_id
    timeout = effective_timeout(timeout_override, state.default_timeout)
    request = request_envelope(id, op, body)
    state = %{state | next_id: id + 1}

    state
    |> call_transport(request, timeout)
    |> reply_from_transport(request)
  end

  def handle_call({:stop, timeout_override}, _from, state) do
    timeout = effective_timeout(timeout_override, state.default_timeout)
    request = request_envelope(state.next_id, "shutdown", %{})
    state = %{state | next_id: state.next_id + 1}

    case state |> call_transport(request, timeout) |> return_from_transport(request) do
      {:ok, _body, next_state} ->
        next_state = close_transport(next_state)
        {:stop, :normal, :ok, next_state}

      {:error, error_body, next_state} ->
        if fatal_error?(error_body) do
          next_state = close_transport(next_state)
          {:stop, :normal, {:error, error_body}, next_state}
        else
          {:reply, {:error, error_body}, next_state}
        end
    end
  end

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
    safe_transport_call(fn -> transport.open(opts) end)
    |> case do
      {:ok, transport_state} -> {:ok, transport_state}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:bad_transport_return, other}}
    end
  end

  defp call_transport(state, request, timeout) do
    case safe_transport_call(fn ->
           state.transport.request(request, state.transport_state, timeout)
         end) do
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

  defp reply_from_transport(transport_result, request) do
    case return_from_transport(transport_result, request) do
      {:ok, body, state} ->
        {:reply, {:ok, body}, state}

      {:error, error_body, state} ->
        if fatal_error?(error_body) do
          state = close_transport(state)
          {:stop, :normal, {:error, error_body}, state}
        else
          {:reply, {:error, error_body}, state}
        end
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

  defp close_transport(%{transport: transport, transport_state: transport_state} = state) do
    _ignored = safe_transport_call(fn -> transport.close(transport_state) end)
    %{state | closed?: true}
  end

  defp safe_transport_call(fun) do
    fun.()
  rescue
    exception -> {:error, {:transport_error, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:transport_error, {kind, reason}}}
  end
end
