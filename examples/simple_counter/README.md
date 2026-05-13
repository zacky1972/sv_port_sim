# Simple Counter Wrapper Example

This example shows a minimal generated interactive-wrapper session for an
8-bit counter with `clk`, active-low `rst_n`, `enable`, and `count` ports.
It is intentionally small enough to use as a regression fixture without
requiring Verilator in every CI job.

## Files

- `counter.sv` - the SystemVerilog counter RTL.
- `signal_specs.json` - canonical `SvPortSim.SignalSpec` metadata for the
  top-level ports.
- `session.jsonl` - a deterministic request/response fixture that documents a
  full reset, poke, cycle, peek, finish probe, and stop session.

## Session summary

The fixture session in `session.jsonl` performs these steps on one running
wrapper process:

1. `reset` with `rst_n` for two cycles, leaving `count == 0`.
2. `poke` `enable` to `1`.
3. `cycle` the design four rising edges. The current public Elixir API calls
   this operation `SvPortSim.tick/2`, so the wire fixture uses `op: "tick"`.
4. `peek` `count`, expecting `%{"bits" => "00000100", "width" => 8}`.
5. `finish?`, expecting `false` because this counter never calls `$finish`.
6. `stop`. The public `SvPortSim.stop/2` call sends the terminal wire operation
   `op: "shutdown"`.

The important behavioral property is that reset, enable, advance, and query all
happen without restarting the wrapper.

## Compile and run when Verilator is available

From the repository root, a caller with the Docker/Verilator backend available
can generate and compile the wrapper with:

```elixir
{:ok, source} = File.read("examples/simple_counter/counter.sv")
{:ok, signal_specs} =
  "examples/simple_counter/signal_specs.json"
  |> File.read!()
  |> JSON.decode()

{:ok, result} =
  SvPortSim.Compiler.compile(
    "Counter",
    %{"Counter" => source},
    signal_specs: signal_specs,
    wrapper_dir: "_build/examples/simple_counter/wrapper"
  )
```

Then drive the compiled executable through the public API:

```elixir
{:ok, sim} = SvPortSim.start_link(executable: result.executable)

{:ok, _reset} = SvPortSim.reset(sim, reset: "rst_n", cycles: 2)
{:ok, _poke} = SvPortSim.poke(sim, "enable", %{"bits" => "1", "width" => 1})
{:ok, _cycle} = SvPortSim.tick(sim, clock: "clk", cycles: 4)
{:ok, %{"value" => %{"bits" => "00000100", "width" => 8}}} =
  SvPortSim.peek(sim, "count")

:ok = SvPortSim.stop(sim)
```

When Verilator is unavailable, keep this example as a compile-only/documentation
fixture and validate `signal_specs.json` plus `session.jsonl` in CI.
