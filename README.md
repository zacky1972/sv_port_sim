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

The default port transport also has a codec boundary between transport I/O and protocol payload handling. By default it uses `SvPortSim.Protocol` to encode request envelopes and decode response envelopes. Tests and alternate runtimes may pass a codec module to the default transport with `transport_opts: [codec: MyCodec]`.

A custom codec module must provide:

  * `encode_request(id, op, body)`, returning `{:ok, payload}` or `{:error, reason}`.
  * `decode_response(payload, expected_id, expected_op)`, returning `{:ok, response_envelope_or_body}` or `{:error, error_body_or_reason}`.


Runtime commands return `{:ok, body}` for successful wrapper responses or `{:error, error_body}` for wrapper-side and Elixir-side failures. `error_body` follows the canonical shape from `SvPortSim.Protocol`, including `"code"`, `"message"`, `"details"`, and `"fatal"`. Fatal errors close the current transport and stop the instance; callers should start a new instance before retrying.

All runtime commands accept `timeout: timeout()`. `reset/2` also accepts `:cycles` and `:reset`; `tick/2` also accepts `:cycles` and `:clock`. `poke/4` accepts `%{bits: bits, width: width}` or `%{"bits" => bits, "width" => width}` and normalizes it to JSON-compatible string-keyed data before sending it to the wrapper.

A typical session is:

```elixir
{:ok, sim} = SvPortSim.start_link(executable: "/path/to/VCounter")
{:ok, _reset} = SvPortSim.reset(sim, cycles: 2, reset: "rst_n")
{:ok, _poke} = SvPortSim.poke(sim, "enable", %{bits: "1", width: 1})
{:ok, _tick} = SvPortSim.tick(sim, cycles: 1, clock: "clk")
{:ok, %{"value" => value}} = SvPortSim.peek(sim, "count")

:ok = SvPortSim.stop(sim)
```


## Generated RTL compile-and-run workflow

`SvPortSim.Compiler.compile/3` can compile a generated SystemVerilog source map into a Verilated wrapper executable, and that executable can then be driven through the public `SvPortSim` runtime API.

The caller provides three pieces of information:

- the top module name,
- an in-memory source map from module name to SystemVerilog source text,
- explicit `SvPortSim.SignalSpec` metadata for the top-level ports.

A minimal generated sequential module can be compiled and driven like this:

```elixir
alias SvPortSim.Compiler
alias SvPortSim.SignalSpec

top_module = "ExampleTop"

sources = %{
  "ExampleXor" => """
  module ExampleXor(
    input  logic [7:0] lhs,
    input  logic [7:0] rhs,
    output logic [7:0] out
  );
    assign out = lhs ^ rhs;
  endmodule
  """,
  "ExampleTop" => """
  module ExampleTop(
    input  logic       clk,
    input  logic       rst,
    input  logic       s_valid,
    input  logic [7:0] a,
    input  logic [7:0] b,
    output logic       m_valid,
    output logic [7:0] y
  );
    logic [7:0] next_y;

    ExampleXor u_xor(
      .lhs(a),
      .rhs(b),
      .out(next_y)
    );

    always_ff @(posedge clk or posedge rst) begin
      if (rst) begin
        m_valid <= 1'b0;
        y       <= 8'h00;
      end else begin
        m_valid <= s_valid;

        if (s_valid) begin
          y <= next_y;
        end
      end
    end
  endmodule
  """
}

signal_specs = [
  SvPortSim.SignalSpec.clock("clk", type: "logic"),
  SvPortSim.SignalSpec.reset("rst", type: "logic", active: "high"),
  SvPortSim.SignalSpec.data("s_valid", "input", "logic", 1),
  SvPortSim.SignalSpec.data("a", "input", "logic", 8),
  SvPortSim.SignalSpec.data("b", "input", "logic", 8),
  SvPortSim.SignalSpec.data("m_valid", "output", "logic", 1),
  SvPortSim.SignalSpec.data("y", "output", "logic", 8)
]

{:ok, build} =
  SvPortSim.Compiler.compile(top_module, sources,
    signal_specs: signal_specs,
    wrapper_dir: "_build/sv_port_sim/example/wrapper",
    work_dir: "_build/sv_port_sim/example/work",
    verilator_args: ["-Wno-fatal"]
  )

{:ok, sim} = SvPortSim.start_link(executable: build.executable)

{:ok, _} = SvPortSim.reset(sim, cycles: 2, clock: "clk", reset: "rst")
{:ok, _} = SvPortSim.poke(sim, "s_valid", %{bits: "1", width: 1})
{:ok, _} = SvPortSim.poke(sim, "a", %{bits: "00001111", width: 8})
{:ok, _} = SvPortSim.poke(sim, "b", %{bits: "11110000", width: 8})
{:ok, _} = SvPortSim.tick(sim, cycles: 1, clock: "clk")
{:ok, %{"value" => y}} = SvPortSim.peek(sim, "y")

:ok = SvPortSim.stop(sim)
```

The example uses scalar `logic` clock/reset/valid ports and one-dimensional packed `logic [7:0]` data ports. Runtime bit strings are ordered most-significant bit first, so `%{bits: "00001111", width: 8}` represents the 8-bit value `8'h0f`.

## Runtime protocol and supported SystemVerilog subset

This is the high-level user-facing runtime contract. The detailed executable specifications live in:

- `SvPortSim.Protocol` for framing, envelopes, timeouts, return values, and runtime error semantics.
- `SvPortSim.Protocol.DataType` for supported runtime value encodings.
- `SvPortSim.SignalSpec` for top-level SystemVerilog port metadata.

### Runtime contract

One `SvPortSim` GenServer owns one simulator transport and serializes all calls to that simulator. The public Elixir API sends request envelopes to the wrapper with monotonically assigned request IDs; the wrapper must return exactly one matching `response` or `error` envelope for each request.

Protocol version 1 uses a four-byte big-endian length-prefixed frame followed by one UTF-8 JSON object:

```text
frame   = uint32_be(byte_size(payload)) <> payload
payload = UTF-8 JSON object
```

Elixir opens the wrapper port with the options returned by `SvPortSim.Protocol.port_options/0`:

```elixir
[:binary, {:packet, 4}, :exit_status]
```

With `{:packet, 4}`, the BEAM adds and strips the length prefix for Elixir. The external wrapper must read and write the four-byte big-endian length prefix explicitly.

The wrapper's stdin/stdout protocol is byte-oriented, not text-oriented. Implementations must preserve every byte of both the four-byte length prefix and the JSON payload. Avoid text or Unicode-transcoding output APIs for framed responses; for example, an Elixir fixture should use raw binary file handles such as `:file.open('/dev/stdout', [:write, :raw, :binary])` and `:file.write/2` rather than writing framed bytes through text stdio helpers. If a length-prefix byte such as `0x93` is transcoded to `0xC2 0x93`, the BEAM packet decoder will wait for the wrong payload length and the request will time out.

Every payload is an envelope with string keys:

```json
{
  "v": 1,
  "id": 0,
  "kind": "request",
  "op": "poke",
  "body": {}
}
```

Envelope fields:

- `"v"` is the protocol version. The MVP version is `1`.
- `"id"` is the request ID assigned by `SvPortSim`; responses and errors must echo it.
- `"kind"` is `"request"`, `"response"`, or `"error"`.
- `"op"` is the runtime operation, such as `"reset"`, `"tick"`, `"poke"`, `"peek"`, or the terminal `"shutdown"` operation used by `stop/2`.
- `"body"` is an operation-specific JSON object.

The maximum JSON payload size is 1 MiB. A zero-length payload is invalid. Elixir runtime calls default to a 5,000 ms timeout unless the instance or command overrides it with a positive integer timeout or `:infinity`.

Successful wrapper responses become `{:ok, body}`. Wrapper-side errors and Elixir-side runtime failures become `{:error, error_body}` where `error_body` has this canonical shape:

```json
{
  "code": "invalid_signal",
  "message": "signal is not readable",
  "details": {"signal": "enable"},
  "fatal": false
}
```

Non-fatal errors keep the simulator usable for the next request. Fatal errors close the current transport; callers must start a new simulator instance before retrying.

### Protocol exchange example

The wrapper receives and returns JSON payload bytes inside the length-prefixed frames. For example, a `poke/4` call may send this request payload:

```json
{
  "v": 1,
  "id": 3,
  "kind": "request",
  "op": "poke",
  "body": {
    "signal": "enable",
    "value": {"bits": "1", "width": 1}
  }
}
```

The wrapper should answer with a matching response envelope:

```json
{
  "v": 1,
  "id": 3,
  "kind": "response",
  "op": "poke",
  "body": {"signal": "enable"}
}
```

A non-fatal wrapper error uses `kind: "error"` and the canonical error-body shape:

```json
{
  "v": 1,
  "id": 4,
  "kind": "error",
  "op": "peek",
  "body": {
    "code": "invalid_signal",
    "message": "unknown signal",
    "details": {"signal": "missing"},
    "fatal": false
  }
}
```

### Supported SystemVerilog subset

The MVP intentionally supports a small, explicit subset of top-level SystemVerilog ports:

| Area | Supported subset |
| --- | --- |
| Port names | Simple SystemVerilog identifiers such as `clk`, `rst_n`, `enable`, and `count` |
| Directions | `input`, `output`, and `inout` |
| Base types | `bit` and `logic` |
| Packed shape | Scalars and one-dimensional packed vectors canonicalized to `[width - 1:0]` |
| Width | `1..4096` bits |
| Signedness | Explicit signed or unsigned metadata for data vectors |
| Roles | `data`, scalar `clock`, and scalar `reset` |
| Clock metadata | `posedge` or `negedge` |
| Reset metadata | active `high` or active `low` |
| Runtime values | `%{"bits" => bits, "width" => width}` with bits ordered most-significant bit to least-significant bit |

Two-state `bit` values may contain only `0` and `1`. Four-state `logic` values may also contain `x` and `z`. Runtime integer views are represented as two-state bit strings; unknown and high-impedance integer values are not part of the MVP.

Signal metadata follows the `SvPortSim.SignalSpec` schema. A typical output vector is represented as:

```elixir
%{
  "name" => "count",
  "direction" => "output",
  "type" => "logic",
  "width" => 8,
  "signed" => false,
  "packed" => %{
    "kind" => "packed_vector",
    "dimensions" => [%{"left" => 7, "right" => 0}]
  },
  "role" => %{"kind" => "data"}
}
```

Unsupported MVP features are rejected rather than guessed. Unsupported features include:

- Escaped identifiers and implicit widths.
- Unpacked arrays, dynamic arrays, associative arrays, queues, and multi-dimensional packed arrays.
- Structs, unions, enums, classes, interfaces, modports, events, `chandle`, strings, and user-defined types.
- `real`, `shortreal`, `realtime`, and `time` values.
- Net strengths, drive strengths, and four-state integer values.
- Non-canonical packed ranges, such as `[0:7]`, unless a wrapper canonicalizes them to `[width - 1:0]` before metadata/runtime exchange.
- Vector clocks and vector resets.
