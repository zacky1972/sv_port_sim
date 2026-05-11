defmodule SvPortSim.Transport do
  @moduledoc """
  Behaviour for simulator transports owned by `SvPortSim`.

  A transport is the boundary between the public `SvPortSim` GenServer and a
  concrete simulator runtime. The default implementation,
  `SvPortSim.Transport.Port`, owns an Erlang port connected to an external C++
  wrapper process. Tests may implement this behaviour in pure Elixir.

  Transport callbacks are invoked synchronously and serially by the owning
  `SvPortSim` GenServer. A transport should not expose its state to callers.
  """

  @typedoc "Opaque state owned by the transport implementation."
  @type state :: term()

  @typedoc "Protocol envelope map as documented by `SvPortSim.Protocol`."
  @type envelope :: %{required(String.t()) => term()}

  @typedoc "Command timeout in milliseconds or `:infinity`."
  @type timeout_ms :: pos_integer() | :infinity

  @doc """
  Opens the simulator transport for one `SvPortSim` instance.

  The callback receives the normalized transport options selected by
  `SvPortSim.start/1` or `SvPortSim.start_link/1`.
  """
  @callback open(keyword()) :: {:ok, state()} | {:error, term()}

  @doc """
  Sends one request envelope and returns the matching response envelope.

  The returned envelope may have `"kind" => "response"` or `"kind" => "error"`.
  Transports may also return `{:error, error_body, state}` for Elixir-side
  runtime failures that are already normalized to the protocol error-body shape.
  """
  @callback request(envelope(), state(), timeout_ms()) ::
              {:ok, envelope(), state()}
              | {:error, map(), state()}
              | {:error, term(), state()}
              | {:error, term()}

  @doc """
  Closes or releases the transport resource.
  """
  @callback close(state()) :: :ok | {:error, term()}
end
