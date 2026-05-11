# SvPortSim

SvPortSim: Elixir interface for driving Verilated SystemVerilog modules through Ports, with each simulation instance managed as a GenServer.

## Public simulation-instance API

One `SvPortSim` process controls one Verilated simulator instance. The process is a GenServer that owns one simulator transport, serializes requests, assigns protocol request IDs, and closes the transport when the instance stops.

The initial stable public functions are:

```elixir
SvPortSim.start_link(opts)
SvPortSim.start(opts)
SvPortSim.child_spec(opts)
SvPortSim.reset(sim, opts \\ [])
SvPortSim.tick(sim, opts \\ [])
SvPortSim.poke(sim, signal, encoded_value, opts \\ [])
SvPortSim.peek(sim, signal, opts \\ [])
SvPortSim.stop(sim, opts \\ [])
SvPortSim.public_functions()
```

The default transport, `SvPortSim.Transport.Port`, opens the wrapper executable with the port framing documented by `SvPortSim.Protocol`. `:executable` is required for that default transport. Tests and alternate runtimes can provide a module implementing `SvPortSim.Transport` via the `:transport` option.

A typical session is:

```elixir
{:ok, sim} = SvPortSim.start_link(executable: "/path/to/VCounter")

{:ok, _reset} = SvPortSim.reset(sim, cycles: 2, reset: "rst_n")
{:ok, _poke} = SvPortSim.poke(sim, "enable", %{bits: "1", width: 1})
{:ok, _tick} = SvPortSim.tick(sim, cycles: 1, clock: "clk")
{:ok, %{"value" => value}} = SvPortSim.peek(sim, "count")

:ok = SvPortSim.stop(sim)
```

Runtime commands return `{:ok, body}` for successful wrapper responses or `{:error, error_body}` for wrapper-side and Elixir-side failures. `error_body` follows the canonical shape from `SvPortSim.Protocol`, including `"code"`, `"message"`, `"details"`, and `"fatal"`. Fatal errors close the current transport and stop the instance; callers should start a new instance before retrying.

All runtime commands accept `timeout: timeout()`. `reset/2` also accepts `:cycles` and `:reset`; `tick/2` also accepts `:cycles` and `:clock`. `poke/4` accepts `%{bits: bits, width: width}` or `%{"bits" => bits, "width" => width}` and normalizes it to JSON-compatible string-keyed data before sending it to the wrapper.

