defmodule SvPortSim do
  @moduledoc """
  A `SvPortSim` process owns exactly one simulator transport. The process
  implementation lives in `SvPortSim.Server`; this module is the public facade
  that keeps the stable user-facing API, validates command options, normalizes
  command bodies, and delegates normalized runtime operations to the server.

  In production the default transport opens one external wrapper process with
  the port framing documented by `SvPortSim.Protocol`; tests and alternative
  runtimes may provide their own `SvPortSim.Transport` implementation.

  ## Public contract

  The initial stable public API surface is returned by `public_functions/0`:

    * `start_link/1` and `start/1`
    * `child_spec/1`
    * `reset/2`
    * `tick/2`
    * `poke/4`
    * `peek/3`
    * `stop/2`

  Default-argument arities such as `reset/1`, `tick/1`, `poke/3`, `peek/2`,
  and `stop/1` are exported for convenience.

  Runtime commands return `{:ok, body}` for a successful wrapper response or
  `{:error, error_body}` for wrapper-side and Elixir-side failures. Error
  bodies follow the canonical shape documented by `SvPortSim.Protocol` and
  include string keys such as `"code"`, `"message"`, `"details"`, and
  `"fatal"`. `stop/2` is terminal and returns `:ok` after a successful
  shutdown.

  ## Options

  `start_link/1` and `start/1` accept these simulation options:

     * `:executable` - path to the generated simulator wrapper executable.
      This is required when using the default `SvPortSim.Transport.Port`
      transport.
   * `:args` - command-line arguments passed to the wrapper executable.
      Defaults to `[]`.
    * `:transport` - module implementing `SvPortSim.Transport`. Defaults to
      `SvPortSim.Transport.Port`.
    * `:transport_opts` - extra keyword options passed to the transport.
      Defaults to `[]`.
    * `:default_timeout` - runtime command timeout in milliseconds or
      `:infinity`. Defaults to `5_000`.

  Standard `GenServer` start options `:name`, `:debug`, `:spawn_opt`,
  `:hibernate_after`, and `:timeout` are also accepted.

  Runtime calls accept `:timeout` to override the instance default. `reset/2`
  accepts `:cycles` and `:reset`; `tick/2` accepts `:cycles` and `:clock`.
  `poke/4` accepts encoded bit-vector values in the shape `%{bits: bits,
  width: width}` or `%{"bits" => bits, "width" => width}`. `bits` must be a
  string of `0`, `1`, `x`, or `z` characters whose length equals `width`.

  ## Examples

      iex> defmodule SvPortSim.DocTransport do
      ...>   @behaviour Elixir.SvPortSim.Transport
      ...>
      ...>   def open(_opts), do: {:ok, %{signals: %{}}}
      ...>
      ...>   def request(%{"op" => "reset"} = request, state, _timeout) do
      ...>     body = %{"cycles" => request["body"]["cycles"]}
      ...>     {:ok, response(request, body), %{state | signals: %{}}}
      ...>   end
      ...>
      ...>   def request(%{"op" => "tick"} = request, state, _timeout) do
      ...>     body = %{"cycles" => request["body"]["cycles"]}
      ...>     {:ok, response(request, body), state}
      ...>   end
      ...>
      ...>   def request(%{"op" => "poke"} = request, state, _timeout) do
      ...>     signal = request["body"]["signal"]
      ...>     value = request["body"]["value"]
      ...>     state = %{state | signals: Map.put(state.signals, signal, value)}
      ...>     {:ok, response(request, %{"signal" => signal}), state}
      ...>   end
      ...>
      ...>   def request(%{"op" => "peek"} = request, state, _timeout) do
      ...>     signal = request["body"]["signal"]
      ...>     value = Map.get(state.signals, signal, %{"bits" => "0", "width" => 1})
      ...>     {:ok, response(request, %{"value" => value}), state}
      ...>   end
      ...>
      ...>   def request(%{"op" => "shutdown"} = request, state, _timeout) do
      ...>     {:ok, response(request, %{}), state}
      ...>   end
      ...>
      ...>   def close(_state), do: :ok
      ...>
      ...>   defp response(request, body) do
      ...>     %{
      ...>       "v" => 1,
      ...>       "id" => request["id"],
      ...>       "kind" => "response",
      ...>       "op" => request["op"],
      ...>       "body" => body
      ...>     }
      ...>   end
      ...> end
      iex> {:ok, sim} = Elixir.SvPortSim.start_link(transport: SvPortSim.DocTransport)
      iex> Elixir.SvPortSim.reset(sim, cycles: 2)
      {:ok, %{"cycles" => 2}}
      iex> Elixir.SvPortSim.tick(sim)
      {:ok, %{"cycles" => 1}}
      iex> Elixir.SvPortSim.poke(sim, "enable", %{bits: "1", width: 1})
      {:ok, %{"signal" => "enable"}}
      iex> Elixir.SvPortSim.peek(sim, "enable")
      {:ok, %{"value" => %{"bits" => "1", "width" => 1}}}
      iex> Elixir.SvPortSim.stop(sim)
      :ok
      iex> Elixir.SvPortSim.start_link([])
      {:error, {:missing_required_option, :executable}}
      iex> {:reset, 2} in Elixir.SvPortSim.public_functions()
      true
  """

  alias SvPortSim.Protocol
  alias SvPortSim.Server

  @public_functions [
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

  @typedoc "A running simulation instance pid, registered name, or via tuple."
  @type instance :: GenServer.server()

  @typedoc "A top-level SystemVerilog signal name exposed by the wrapper."
  @type signal :: atom() | String.t()

  @typedoc "Encoded runtime bit-vector value accepted by `poke/4`."
  @type encoded_value :: %{
          optional(:bits) => String.t(),
          optional(:width) => pos_integer(),
          optional(String.t()) => String.t() | pos_integer()
        }

  @typedoc "Command response body returned by the wrapper."
  @type response_body :: %{required(String.t()) => term()}

  @typedoc "Canonical runtime error body documented by `SvPortSim.Protocol`."
  @type error_body :: %{required(String.t()) => term()}

  @typedoc "Public API timeout in milliseconds or `:infinity`."
  @type timeout_ms :: pos_integer() | :infinity

  @typedoc "Public API result returned by runtime commands except `stop/2`."
  @type api_result :: {:ok, response_body()} | {:error, error_body()}

  @typedoc "Options accepted by `start_link/1`, `start/1`, and `child_spec/1`."
  @type start_option ::
          {:executable, Path.t()}
          | {:args, [String.t()]}
          | {:transport, module()}
          | {:transport_opts, keyword()}
          | {:default_timeout, timeout()}
          | {:name, GenServer.name()}
          | {:debug, term()}
          | {:spawn_opt, [term()]}
          | {:hibernate_after, non_neg_integer()}
          | {:timeout, timeout_ms()}
          | {:id, term()}

  @typedoc "Per-command options accepted by `poke/4`, `peek/3`, and `stop/2`."
  @type command_option :: {:timeout, timeout_ms()}

  @typedoc "Options accepted by `reset/2`."
  @type reset_option ::
          command_option()
          | {:cycles, pos_integer()}
          | {:reset, signal()}
          | {:clock, signal()}

  @typedoc "Options accepted by `tick/2`."
  @type tick_option :: command_option() | {:cycles, pos_integer()} | {:clock, signal()}

  @doc """
  Returns the stable public API surface for one simulation instance.

  Internal server functions are intentionally not included in this list.

  ## Examples

      iex> SvPortSim.public_functions() |> Enum.member?({:start_link, 1})
      true
      iex> SvPortSim.public_functions() |> Enum.member?({:poke, 4})
      true
  """
  @spec public_functions() :: [{atom(), non_neg_integer()}]
  def public_functions(), do: @public_functions

  @doc """
  Starts one simulation instance and links it to the caller.
  """
  @spec start_link([start_option()]) :: GenServer.on_start()
  def start_link(opts) when is_list(opts), do: Server.start_link(opts)
  def start_link(opts), do: {:error, {:invalid_options, opts}}

  @doc """
  Starts one simulation instance without linking it to the caller.
  """
  @spec start([start_option()]) :: GenServer.on_start()
  def start(opts) when is_list(opts), do: Server.start(opts)
  def start(opts), do: {:error, {:invalid_options, opts}}

  @doc """
  Returns a child spec for supervising one simulation instance.

  Pass `:id` to override the child id. Other options are passed to
  `start_link/1`.
  """
  @spec child_spec([start_option()]) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      id = Keyword.get(opts, :id, __MODULE__)
      start_opts = Keyword.delete(opts, :id)

      %{
        id: id,
        start: {__MODULE__, :start_link, [start_opts]},
        type: :worker,
        restart: :permanent,
        shutdown: 5_000
      }
    else
      raise ArgumentError, "child_spec/1 expects a keyword list"
    end
  end

  @doc """
  Resets the simulator.

  Options:

    * `:cycles` - number of reset cycles. Defaults to `1`.
    * `:reset` - reset signal name. Defaults to wrapper policy.
    * `:clock` - clock signal name. Defaults to wrapper policy.
    * `:timeout` - per-request timeout.
  """
  @spec reset(instance(), [reset_option()]) :: api_result()
  def reset(instance, opts \\ []) do
    with {:ok, body} <- build_reset_body(opts) do
      request(instance, "reset", body, opts)
    end
  end

  @doc """
  Advances the simulator by one or more clock cycles.

  Options:

    * `:cycles` - number of cycles. Defaults to `1`.
    * `:clock` - clock signal name. Defaults to wrapper policy.
    * `:timeout` - per-request timeout.
  """
  @spec tick(instance(), [tick_option()]) :: api_result()
  def tick(instance, opts \\ []) do
    with {:ok, body} <- build_tick_body(opts) do
      request(instance, "tick", body, opts)
    end
  end

  @doc """
  Writes an encoded value to a signal.

  `encoded_value` must be `%{bits: bits, width: width}` or
  `%{"bits" => bits, "width" => width}`. The value is normalized to
  string-keyed JSON-compatible data before it is sent to the transport.
  """
  @spec poke(instance(), signal(), encoded_value(), [command_option()]) :: api_result()
  def poke(instance, signal, encoded_value, opts \\ []) do
    with {:ok, _opts} <- validate_keyword_options(opts),
         {:ok, _opts} <- validate_allowed_options(opts, [:timeout]),
         {:ok, signal} <- normalize_signal(signal),
         {:ok, value} <- normalize_encoded_value(encoded_value) do
      request(instance, "poke", %{"signal" => signal, "value" => value}, opts)
    end
  end

  @doc """
  Reads a signal from the simulator.
  """
  @spec peek(instance(), signal(), [command_option()]) :: api_result()
  def peek(instance, signal, opts \\ []) do
    with {:ok, _opts} <- validate_keyword_options(opts),
         {:ok, _opts} <- validate_allowed_options(opts, [:timeout]),
         {:ok, signal} <- normalize_signal(signal) do
      request(instance, "peek", %{"signal" => signal}, opts)
    end
  end

  @doc """
  Sends the terminal shutdown command and stops the simulation instance.

  Returns `:ok` after the wrapper acknowledges shutdown and the transport is
  closed. Returns `{:error, error_body}` if the shutdown request fails.
  """
  @spec stop(instance(), [command_option()]) :: :ok | {:error, error_body()}
  def stop(instance, opts \\ []) do
    with {:ok, _opts} <- validate_keyword_options(opts),
         {:ok, _opts} <- validate_allowed_options(opts, [:timeout]),
         {:ok, timeout_override} <- command_timeout_override(opts) do
      Server.stop(instance, timeout_override)
    end
  end

  defp request(instance, op, body, opts) do
    with {:ok, timeout_override} <- command_timeout_override(opts) do
      Server.request(instance, op, body, timeout_override)
    end
  end

  defp build_reset_body(opts) do
    with {:ok, _opts} <- validate_keyword_options(opts),
         {:ok, _opts} <- validate_allowed_options(opts, [:cycles, :reset, :clock, :timeout]),
         {:ok, cycles} <- positive_integer_option(opts, :cycles, 1),
         {:ok, body} <- optional_signal(%{"cycles" => cycles}, opts, :reset) do
      optional_signal(body, opts, :clock)
    end
  end

  defp build_tick_body(opts) do
    with {:ok, _opts} <- validate_keyword_options(opts),
         {:ok, _opts} <- validate_allowed_options(opts, [:cycles, :clock, :timeout]),
         {:ok, cycles} <- positive_integer_option(opts, :cycles, 1) do
      optional_signal(%{"cycles" => cycles}, opts, :clock)
    end
  end

  defp optional_signal(body, opts, key) do
    case Keyword.fetch(opts, key) do
      :error ->
        {:ok, body}

      {:ok, signal} ->
        with {:ok, signal} <- normalize_signal(signal) do
          {:ok, Map.put(body, Atom.to_string(key), signal)}
        end
    end
  end

  defp validate_keyword_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      {:ok, opts}
    else
      validation_error("options must be a keyword list", %{"options" => inspect(opts)})
    end
  end

  defp validate_keyword_options(opts) do
    validation_error("options must be a keyword list", %{"options" => inspect(opts)})
  end

  defp validate_allowed_options(opts, allowed) do
    unknown = Keyword.keys(opts) -- allowed

    if unknown == [] do
      {:ok, opts}
    else
      validation_error("unknown option", %{
        "allowed" => Enum.map(allowed, &Atom.to_string/1),
        "unknown" => Enum.map(unknown, &Atom.to_string/1)
      })
    end
  end

  defp positive_integer_option(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value > 0 do
      {:ok, value}
    else
      validation_error("#{key} must be a positive integer", %{Atom.to_string(key) => value})
    end
  end

  defp command_timeout_override(opts) do
    command_timeout_override_case(validate_keyword_options(opts))
  end

  defp command_timeout_override_case({:ok, opts}) do
    case Keyword.fetch(opts, :timeout) do
      :error ->
        {:ok, :default}

      {:ok, timeout} ->
        case Protocol.normalize_timeout(timeout) do
          {:ok, normalized} ->
            {:ok, normalized}

          {:error, reason} ->
            validation_error("timeout must be a positive integer or :infinity", %{
              "reason" => inspect(reason),
              "timeout" => inspect(timeout)
            })
        end
    end
  end

  defp command_timeout_override_case({:error, _error_body} = error), do: error

  defp normalize_signal(signal) when is_atom(signal) and signal not in [nil, true, false] do
    signal
    |> Atom.to_string()
    |> normalize_signal()
  end

  defp normalize_signal(signal) when is_binary(signal) and byte_size(signal) > 0 do
    {:ok, signal}
  end

  defp normalize_signal(signal) do
    validation_error("signal must be a non-empty string or atom", %{"signal" => inspect(signal)})
  end

  defp normalize_encoded_value(%{} = encoded_value) do
    bits = Map.get(encoded_value, :bits, Map.get(encoded_value, "bits"))
    width = Map.get(encoded_value, :width, Map.get(encoded_value, "width"))

    cond do
      not is_binary(bits) ->
        validation_error("encoded value bits must be a string", %{"bits" => inspect(bits)})

      not (is_integer(width) and width > 0) ->
        validation_error("encoded value width must be a positive integer", %{
          "width" => inspect(width)
        })

      String.length(bits) != width ->
        validation_error("encoded value width must match bit-string length", %{
          "bits" => bits,
          "width" => width
        })

      not valid_bit_string?(bits) ->
        validation_error("encoded value bits may only contain 0, 1, x, or z", %{"bits" => bits})

      true ->
        {:ok, %{"bits" => bits, "width" => width}}
    end
  end

  defp normalize_encoded_value(value) do
    validation_error("encoded value must be a map", %{"value" => inspect(value)})
  end

  defp valid_bit_string?(bits) do
    bits
    |> String.to_charlist()
    |> Enum.all?(&(&1 in ~c"01xz"))
  end

  defp validation_error(message, details) do
    case Protocol.error_body("invalid_request", message, details) do
      {:ok, body} ->
        {:error, body}

      {:error, reason} ->
        {:error,
         %{
           "code" => "invalid_request",
           "message" => inspect(reason),
           "details" => details,
           "fatal" => false
         }}
    end
  end
end
