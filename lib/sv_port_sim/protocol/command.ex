defmodule SvPortSim.Protocol.Command do
  @moduledoc """
  Defines the MVP command and response protocol for the C++ wrapper process.

  `SvPortSim.Protocol` defines the length-prefixed JSON envelope. This module defines the
  commands carried by that envelope.

  The MVP command names are:

    * `"metadata"` - discover the top module, signal metadata, protocol version, and current
      simulation cycle
    * `"reset"` - drive the wrapper-defined reset sequence
    * `"poke"` - assign one writable Verilated top-level signal
    * `"tick"` - advance the simulation by one or more clock cycles
    * `"peek"` - read one Verilated top-level signal
    * `"shutdown"` - flush the final response and terminate the wrapper process

  ## Runtime model and lifecycle

  The MVP supports exactly one simulation instance per OS process. On startup, the C++ wrapper
  constructs one `VerilatedContext` and one Verilated top-module instance, initializes its
  internal cycle counter to `0`, then waits for framed JSON requests on standard input. There is
  no `instance_id` field in the MVP.

  The protocol is synchronous. The Elixir side sends one request, waits for the matching response,
  and only then sends the next request. The wrapper must read requests in frame order and must
  emit exactly one response or error envelope for each well-formed request envelope, using the
  same `id` and `op`.

  If the frame, JSON payload, or common envelope is not recoverable enough to identify an `id`,
  the wrapper should treat that condition as a fatal protocol error and exit non-zero. If an
  envelope is well formed but the command name, body, signal name, value, unsupported feature, or
  current simulator state is invalid, the wrapper must return a `kind: "error"` envelope and keep
  running unless the error body explicitly sets `"fatal" => true`.

  `"shutdown"` is the terminal command. After writing and flushing the successful shutdown
  response, the wrapper calls `final()` on the Verilated model and exits with status `0`. No
  further request is accepted by that process.

  ## Common request envelope

  Every command request uses the common `SvPortSim.Protocol` envelope:

      {
        "v": 1,
        "id": 1,
        "kind": "request",
        "op": "peek",
        "body": {"signal": "count"}
      }

  Successful responses use `kind: "response"` and the same `id` and `op`. Command failures use
  `kind: "error"` and the canonical runtime error body from `SvPortSim.Protocol.error_body/4`:

      {
        "code": "invalid_signal",
        "message": "signal is not readable",
        "details": {"signal": "enable"},
        "fatal": false
      }

  ## Command schemas

  All object keys are JSON strings. Unknown request fields are invalid.

  ### `metadata`

    * Request body: `{}`
    * Response body: `%{"top" => top_module, "signals" => signal_specs, "cycle" => cycle}`
    * Wrapper operation: return static metadata for the single model instance.
    * Idempotency: idempotent; it must not call `eval()` or advance time.

  `signals` is a list of metadata objects. The command layer intentionally only constrains it to
  a list; the exact signal metadata schema is owned by the signal-spec contract.

  ### `reset`

    * Request body: `%{"cycles" => positive_integer}`. `"cycles"` is optional and defaults to `1`.
    * Response body: `%{"cycle" => cycle, "reset" => %{"cycles" => cycles}}`
    * Wrapper operation: drive reset-role signal or signals active, advance the requested number
      of cycles using the wrapper's clocking policy, deassert reset, settle the model with
      `eval()`, and return the resulting cycle.
    * Idempotency: not idempotent because it advances the cycle counter.

  ### `poke`

    * Request body: `%{"signal" => writable_signal_name, "value" => encoded_value}`
    * Response body: `%{"signal" => signal_name, "value" => encoded_value, "cycle" => cycle}`
    * Wrapper operation: assign the decoded value to the matching Verilated top-level field, call
      `eval()` once to settle combinational outputs, and return the canonical value actually
      stored by the wrapper.
    * Idempotency: idempotent for the same signal and value at the same cycle. It must not advance
      the cycle counter.

  `encoded_value` is `%{"bits" => bit_string, "width" => positive_integer}`. Bit strings are
  most-significant bit first and may contain `0`, `1`, `x`, and `z`.

  ### `tick`

    * Request body: `%{"cycles" => positive_integer, "clock" => signal_name}`. Both fields are
      optional. `"cycles"` defaults to `1`. `"clock"` may be omitted only when wrapper metadata
      defines exactly one clock signal.
    * Response body: `%{"cycle" => cycle, "clock" => clock_name, "cycles" => cycles}`
    * Wrapper operation: for each requested cycle, perform one complete clock cycle according to
      the wrapper's clocking policy and call `eval()` at each driven edge needed by the generated
      model. Increment the cycle counter by one per completed cycle.
    * Idempotency: not idempotent because it advances simulation state.

  ### `peek`

    * Request body: `%{"signal" => readable_signal_name}`
    * Response body: `%{"signal" => signal_name, "value" => encoded_value, "cycle" => cycle}`
    * Wrapper operation: read the matching Verilated top-level field after all previous commands
      have completed. The wrapper may call `eval()` first if needed to settle combinational
      outputs, but it must not advance the cycle counter.
    * Idempotency: idempotent when no intervening state-changing command occurs.

  ### `shutdown`

    * Request body: `{}`
    * Response body: `%{"status" => "closing"}`
    * Wrapper operation: send the response, flush stdout, call `final()`, release resources, and
      exit with status `0`.
    * Idempotency: terminal.

  ## Example protocol exchange

  The following exchange is a complete reset/poke/tick/peek sequence for a minimal Verilated
  counter wrapper. The example top module has one clock, one active-low reset, one writable input,
  and one readable output:

      module Counter(
        input  logic       clk,
        input  logic       rst_n,
        input  logic       enable,
        output logic [3:0] count
      );
        always_ff @(posedge clk or negedge rst_n) begin
          if (!rst_n) begin
            count <= 4'd0;
          end else if (enable) begin
            count <= count + 4'd1;
          end
        end
      endmodule

  The wrapper starts at simulation cycle `0`. Each JSON value below is the exact UTF-8 payload
  inside one protocol frame. On the actual C++ side, every payload is sent as
  `uint32_be(byte_size(payload)) <> payload`. When Elixir opens the port with `{:packet, 4}`, it
  sends and receives only the payload bytes because the BEAM adds and removes the 4-byte length
  prefix.

  JSON member order is not significant, but this example uses a compact stable order so C++ and
  Elixir implementers can compare logs byte-for-byte.

  ### 1. Reset

  Elixir sends an 80-byte payload (`0x00000050` length prefix) requesting a two-cycle reset on
  `rst_n`:

  ```json
  {"v":1,"id":1,"kind":"request","op":"reset","body":{"cycles":2,"reset":"rst_n"}}
  ```

  The C++ wrapper drives reset active for two clock cycles, deasserts it, settles the model, and
  returns the resulting cycle in a 102-byte payload (`0x00000066` length prefix):

  ```json
  {"v":1,"id":1,"kind":"response","op":"reset","body":{"cycle":2,"reset":{"cycles":2,"signal":"rst_n"}}}
  ```

  ### 2. Poke

  Elixir writes `enable = 1` using the canonical bit-string value encoding. The request is a
  101-byte payload (`0x00000065` length prefix):

  ```json
  {"v":1,"id":2,"kind":"request","op":"poke","body":{"signal":"enable","value":{"bits":"1","width":1}}}
  ```

  The wrapper assigns the top-level signal, calls `eval()` to settle combinational logic, does not
  advance the cycle counter, and echoes the stored canonical value in a 112-byte payload
  (`0x00000070` length prefix):

  ```json
  {"v":1,"id":2,"kind":"response","op":"poke","body":{"signal":"enable","value":{"bits":"1","width":1},"cycle":2}}
  ```

  ### 3. Tick

  Elixir advances one full cycle on `clk`. The request is a 77-byte payload (`0x0000004d` length
  prefix):

  ```json
  {"v":1,"id":3,"kind":"request","op":"tick","body":{"clock":"clk","cycles":1}}
  ```

  The wrapper performs one complete clock cycle, increments its cycle counter to `3`, and returns
  an 88-byte payload (`0x00000058` length prefix):

  ```json
  {"v":1,"id":3,"kind":"response","op":"tick","body":{"clock":"clk","cycles":1,"cycle":3}}
  ```

  ### 4. Peek

  Elixir reads `count` without advancing time. The request is a 69-byte payload (`0x00000045`
  length prefix):

  ```json
  {"v":1,"id":4,"kind":"request","op":"peek","body":{"signal":"count"}}
  ```

  Because reset put `count` at zero and the enabled tick incremented it once, the wrapper returns
  `0001` as a 4-bit most-significant-bit-first value. The response is a 114-byte payload
  (`0x00000072` length prefix):

  ```json
  {"v":1,"id":4,"kind":"response","op":"peek","body":{"signal":"count","value":{"bits":"0001","width":4},"cycle":3}}
  ```

  ### 5. Non-fatal error example

  A well-formed command for an unknown or unreadable signal is a command-layer error, not a fatal
  protocol failure. Elixir sends a 71-byte payload (`0x00000047` length prefix):

  ```json
  {"v":1,"id":5,"kind":"request","op":"peek","body":{"signal":"missing"}}
  ```

  The wrapper returns one `kind: "error"` envelope with the same `id` and `op`, keeps the simulator
  process running, and accepts the next request. The response is a 146-byte payload
  (`0x00000092` length prefix):

  ```json
  {"v":1,"id":5,"kind":"error","op":"peek","body":{"code":"invalid_signal","message":"unknown signal","details":{"signal":"missing"},"fatal":false}}
  ```

  ## Examples

  The MVP command set is fixed and ordered for documentation and tests.

      iex> SvPortSim.Protocol.Command.command_names()
      ["metadata", "reset", "eval", "poke", "tick", "cycle", "peek", "finish?", "shutdown"]

  Metadata discovery uses an empty request body and reports the model metadata.

      iex> {:ok, request} = SvPortSim.Protocol.Command.request("metadata", 1)
      iex> {request["kind"], request["op"], request["body"]}
      {"request", "metadata", %{}}
      iex> {:ok, response} = SvPortSim.Protocol.Command.ok_response(request, %{"top" => "Counter", "signals" => [], "cycle" => 0})
      iex> {response["kind"], response["body"]["top"], response["body"]["cycle"]}
      {"response", "Counter", 0}

  Reset advances the simulator through the wrapper-defined reset sequence.

      iex> {:ok, request} = SvPortSim.Protocol.Command.request("reset", 2, %{"cycles" => 2})
      iex> SvPortSim.Protocol.Command.validate_request(request)
      :ok
      iex> {:ok, response} = SvPortSim.Protocol.Command.ok_response(request, %{"cycle" => 2, "reset" => %{"cycles" => 2}})
      iex> response["body"]["reset"]["cycles"]
      2

  Poke assigns one writable signal using the runtime bit-string encoding.

      iex> value = %{"bits" => "1", "width" => 1}
      iex> {:ok, request} = SvPortSim.Protocol.Command.request("poke", 3, %{"signal" => "enable", "value" => value})
      iex> request["body"]["signal"]
      "enable"
      iex> {:ok, response} = SvPortSim.Protocol.Command.ok_response(request, %{"signal" => "enable", "value" => value, "cycle" => 2})
      iex> response["body"]["value"]
      %{"bits" => "1", "width" => 1}

  Tick advances one or more complete clock cycles.

      iex> {:ok, request} = SvPortSim.Protocol.Command.request("tick", 4, %{"clock" => "clk", "cycles" => 1})
      iex> {:ok, response} = SvPortSim.Protocol.Command.ok_response(request, %{"clock" => "clk", "cycles" => 1, "cycle" => 3})
      iex> {request["op"], response["body"]["cycle"]}
      {"tick", 3}

  Peek reads one signal without advancing the cycle counter.

      iex> {:ok, request} = SvPortSim.Protocol.Command.request("peek", 5, %{"signal" => "count"})
      iex> {:ok, response} = SvPortSim.Protocol.Command.ok_response(request, %{"signal" => "count", "value" => %{"bits" => "0001", "width" => 4}, "cycle" => 3})
      iex> response["body"]["value"]["bits"]
      "0001"

  Shutdown is the final successful command in a wrapper process.

      iex> {:ok, request} = SvPortSim.Protocol.Command.request("shutdown", 6)
      iex> {:ok, response} = SvPortSim.Protocol.Command.ok_response(request, %{"status" => "closing"})
      iex> response["body"]["status"]
      "closing"

  Unsupported commands and invalid command bodies are explicit error paths.

      iex> SvPortSim.Protocol.Command.request("step", 7)
      {:error, {:unsupported_command, "step"}}
      iex> {:ok, request} = SvPortSim.Protocol.Command.request("peek", 8, %{"signal" => "count"})
      iex> {:ok, error} = SvPortSim.Protocol.Command.error_response(request, "invalid_signal", "signal is not readable", %{"signal" => "count"})
      iex> {error["kind"], error["body"]["code"], error["body"]["fatal"]}
      {"error", "invalid_signal", false}

  Fatal error responses can be built explicitly when the wrapper cannot safely continue.

      iex> {:ok, error} = SvPortSim.Protocol.Command.error_response(9, "tick", "wrapper_fault", "segmentation fault", %{}, fatal: true)
      iex> {error["kind"], error["body"]["code"], error["body"]["fatal"]}
      {"error", "wrapper_fault", true}
  """

  alias SvPortSim.Protocol

  @command_names ~w(metadata reset eval poke tick cycle peek finish? shutdown)
  @error_codes ~w(
    invalid_command
    unsupported_command
    invalid_request
    invalid_signal
    invalid_value
    invalid_state
    unsupported_feature
    protocol_error
    timeout
    malformed_output
    simulator_exit
    simulator_failure
    port_closed
    wrapper_fault
  )

  @command_specs [
    %{
      name: "metadata",
      request: %{required: %{}, optional: %{}},
      response: %{
        required: %{"top" => "string", "signals" => "list", "cycle" => "non_neg_integer"},
        optional: %{"protocol" => "object"}
      },
      wrapper_operation: "Return static metadata for the single Verilated model instance.",
      idempotency: :idempotent,
      errors:
        ~w(unsupported_command invalid_request invalid_state unsupported_feature wrapper_fault)
    },
    %{
      name: "reset",
      request: %{
        required: %{},
        optional: %{"cycles" => "positive_integer", "reset" => "string"},
        defaults: %{"cycles" => 1}
      },
      response: %{
        required: %{
          "cycle" => "non_neg_integer",
          "reset" => "%{\"cycles\" => positive_integer}"
        },
        optional: %{}
      },
      wrapper_operation:
        "Drive reset active, tick the requested cycles, deassert reset, and settle with eval().",
      idempotency: :state_changing,
      errors:
        ~w(unsupported_command invalid_request invalid_signal invalid_value invalid_state unsupported_feature wrapper_fault)
    },
    %{
      name: "eval",
      request: %{required: %{}, optional: %{}},
      response: %{
        required: %{
          "time" => "non_neg_integer",
          "cycle" => "non_neg_integer"
        },
        optional: %{}
      },
      wrapper_operation: "Call eval() once to settle the current model state without advancing simulation time or cycle.",
      idempotency: :idempotent,
      errors: ~w(unsupported_command invalid_request invalid_state unsupported_feature wrapper_fault)
    },
    %{
      name: "poke",
      request: %{
        required: %{"signal" => "string", "value" => "encoded_value"},
        optional: %{}
      },
      response: %{
        required: %{
          "signal" => "string",
          "value" => "encoded_value",
          "cycle" => "non_neg_integer"
        },
        optional: %{}
      },
      wrapper_operation: "Assign the top-level field, call eval(), and return the stored value.",
      idempotency: :idempotent_at_same_cycle,
      errors:
        ~w(unsupported_command invalid_request invalid_signal invalid_value invalid_state unsupported_feature wrapper_fault)
    },
    %{
      name: "tick",
      request: %{
        required: %{},
        optional: %{"clock" => "string", "cycles" => "positive_integer"},
        defaults: %{"cycles" => 1}
      },
      response: %{
        required: %{
          "clock" => "string",
          "cycles" => "positive_integer",
          "cycle" => "non_neg_integer"
        },
        optional: %{}
      },
      wrapper_operation: "Advance complete clock cycles and increment the cycle counter.",
      idempotency: :state_changing,
      errors:
        ~w(unsupported_command invalid_request invalid_signal invalid_value invalid_state unsupported_feature wrapper_fault)
    },
    %{
      name: "cycle",
      request: %{
        required: %{"cycles" => "positive_integer"},
        optional: %{"clock" => "string"}
      },
      response: %{
        required: %{
          "clock" => "string",
          "cycles" => "positive_integer",
          "cycle" => "non_neg_integer"
        },
        optional: %{"time" => "non_neg_integer"}
      },
      wrapper_operation: "Advance the requested number of complete clock cycles on the selected clock.",
      idempotency: :state_changing,
      errors: ~w(unsupported_command invalid_request invalid_signal invalid_value invalid_state unsupported_feature wrapper_fault)
    },
    %{
      name: "peek",
      request: %{required: %{"signal" => "string"}, optional: %{}},
      response: %{
        required: %{
          "signal" => "string",
          "value" => "encoded_value",
          "cycle" => "non_neg_integer"
        },
        optional: %{}
      },
      wrapper_operation: "Read the top-level field after previous commands complete.",
      idempotency: :read_only,
      errors:
        ~w(unsupported_command invalid_request invalid_signal invalid_state unsupported_feature wrapper_fault)
    },
    %{
      name: "finish?",
      request: %{required: %{}, optional: %{}},
      response: %{
        required: %{
          "finished" => "boolean",
          "time" => "non_neg_integer",
          "cycle" => "non_neg_integer"
        },
        optional: %{}
      },
      wrapper_operation: "Query whether Verilator has requested finish without terminating the wrapper process.",
      idempotency: :read_only,
      errors: ~w(unsupported_command invalid_request invalid_state wrapper_fault)
    },
    %{
      name: "shutdown",
      request: %{required: %{}, optional: %{}},
      response: %{required: %{"status" => "closing"}, optional: %{}},
      wrapper_operation:
        "Flush the response, call final(), release resources, and exit status 0.",
      idempotency: :terminal,
      errors: ~w(unsupported_command invalid_request invalid_state wrapper_fault)
    }
  ]

  @type command_name :: String.t()
  @type request_id :: non_neg_integer()
  @type encoded_value :: %{required(String.t()) => String.t() | pos_integer()}
  @type envelope :: %{required(String.t()) => term()}
  @type command_spec :: %{
          required(:name) => command_name(),
          required(:request) => map(),
          required(:response) => map(),
          required(:wrapper_operation) => String.t(),
          required(:idempotency) => atom(),
          required(:errors) => [String.t()]
        }

  @doc """
  Returns the MVP command names in protocol-documentation order.

  ## Examples

      iex> SvPortSim.Protocol.Command.command_names()
      ["metadata", "reset", "eval", "poke", "tick", "cycle", "peek", "finish?", "shutdown"]
  """
  @spec command_names() :: [command_name()]
  def command_names(), do: @command_names

  @doc """
  Returns the supported runtime error codes.

  ## Examples

      iex> "invalid_signal" in SvPortSim.Protocol.Command.error_codes()
      true

      iex> "unsupported_feature" in SvPortSim.Protocol.Command.error_codes()
      true
  """
  @spec error_codes() :: [String.t()]
  def error_codes(), do: @error_codes

  @doc """
  Returns command schema and wrapper-obligation metadata for every MVP command.

  ## Examples

      iex> SvPortSim.Protocol.Command.command_specs() |> Enum.map(& &1.name)
      ["metadata", "reset", "eval", "poke", "tick", "cycle", "peek", "finish?", "shutdown"]
  """
  @spec command_specs() :: [command_spec()]
  def command_specs(), do: @command_specs

  @doc """
  Looks up one command specification.

  ## Examples

      iex> {:ok, spec} = SvPortSim.Protocol.Command.command_spec("poke")
      iex> spec.request.required["value"]
      "encoded_value"

      iex> SvPortSim.Protocol.Command.command_spec("step")
      {:error, {:unsupported_command, "step"}}
  """
  @spec command_spec(term()) :: {:ok, command_spec()} | {:error, term()}
  def command_spec(command) when is_binary(command) do
    case Enum.find(@command_specs, &(&1.name == command)) do
      nil -> {:error, {:unsupported_command, command}}
      spec -> {:ok, spec}
    end
  end

  def command_spec(command), do: {:error, {:unsupported_command, command}}

  @doc """
  Looks up one command specification, raising `ArgumentError` on failure.

  ## Examples

      iex> SvPortSim.Protocol.Command.command_spec!("shutdown").idempotency
      :terminal
  """
  @spec command_spec!(term()) :: command_spec()
  def command_spec!(command) do
    case command_spec(command) do
      {:ok, spec} -> spec
      {:error, reason} -> raise ArgumentError, message: inspect(reason)
    end
  end

  @doc """
  Returns whether `command` is an MVP command name.

  ## Examples

      iex> SvPortSim.Protocol.Command.supported?("peek")
      true

      iex> SvPortSim.Protocol.Command.supported?("step")
      false
  """
  @spec supported?(term()) :: boolean()
  def supported?(command), do: match?({:ok, _spec}, command_spec(command))

  @doc """
  Builds a validated command request envelope.

  ## Examples

      iex> {:ok, request} = SvPortSim.Protocol.Command.request("peek", 1, %{"signal" => "count"})
      iex> {request["v"], request["id"], request["kind"], request["op"]}
      {1, 1, "request", "peek"}

      iex> SvPortSim.Protocol.Command.request("peek", -1, %{"signal" => "count"})
      {:error, {:invalid_request_id, -1}}
  """
  @spec request(term(), term(), map()) :: {:ok, envelope()} | {:error, term()}
  def request(command, id, body \\ %{})

  def request(command, id, body)
      when is_binary(command) and is_integer(id) and id >= 0 and is_map(body) do
    with :ok <- validate_request_body(command, body) do
      {:ok,
       %{
         "v" => Protocol.version(),
         "id" => id,
         "kind" => "request",
         "op" => command,
         "body" => body
       }}
    end
  end

  def request(_command, id, _body) when not (is_integer(id) and id >= 0) do
    {:error, {:invalid_request_id, id}}
  end

  def request(command, _id, body) when not is_binary(command) or not is_map(body) do
    {:error, {:invalid_request_arguments, command, body}}
  end

  @doc """
  Builds a validated successful response envelope from a request envelope.

  ## Examples

      iex> {:ok, request} = SvPortSim.Protocol.Command.request("shutdown", 9)
      iex> {:ok, response} = SvPortSim.Protocol.Command.ok_response(request, %{"status" => "closing"})
      iex> {response["id"], response["kind"], response["op"]}
      {9, "response", "shutdown"}
  """
  @spec ok_response(envelope(), map()) :: {:ok, envelope()} | {:error, term()}
  def ok_response(request, body \\ %{})

  def ok_response(%{"id" => id, "op" => command}, body) do
    ok_response(id, command, body)
  end

  def ok_response(%{id: id, op: command}, body) do
    ok_response(id, command, body)
  end

  def ok_response(request, _body), do: {:error, {:invalid_request, request}}

  @doc """
  Builds a validated successful response envelope from an id, command, and body.

  ## Examples

      iex> {:ok, response} = SvPortSim.Protocol.Command.ok_response(1, "metadata", %{"top" => "Counter", "signals" => [], "cycle" => 0})
      iex> {response["kind"], response["op"]}
      {"response", "metadata"}
  """
  @spec ok_response(term(), term(), map()) :: {:ok, envelope()} | {:error, term()}
  def ok_response(id, command, body)
      when is_integer(id) and id >= 0 and is_binary(command) and is_map(body) do
    with :ok <- validate_response_body(command, body) do
      {:ok,
       %{
         "v" => Protocol.version(),
         "id" => id,
         "kind" => "response",
         "op" => command,
         "body" => body
       }}
    end
  end

  def ok_response(id, command, body) do
    {:error, {:invalid_response_arguments, id, command, body}}
  end

  @doc """
  Builds a validated error response envelope from a request envelope.

  ## Examples

      iex> {:ok, request} = SvPortSim.Protocol.Command.request("peek", 10, %{"signal" => "missing"})
      iex> {:ok, error} = SvPortSim.Protocol.Command.error_response(request, "invalid_signal", "unknown signal", %{"signal" => "missing"})
      iex> {error["id"], error["kind"], error["body"]["code"]}
      {10, "error", "invalid_signal"}
  """
  @spec error_response(envelope() | request_id(), String.t(), String.t(), map()) ::
          {:ok, envelope()} | {:error, term()}
  def error_response(request_or_id, code, message, details \\ %{})

  def error_response(%{"id" => id, "op" => command}, code, message, details) do
    error_response(id, command, code, message, details)
  end

  def error_response(%{id: id, op: command}, code, message, details) do
    error_response(id, command, code, message, details)
  end

  def error_response(id, code, message, details) when is_integer(id) do
    error_response(id, "unknown", code, message, details)
  end

  def error_response(request, _code, _message, _details),
    do: {:error, {:invalid_request, request}}

  @doc """
  Builds a validated error response envelope from an id, command, error code, message, and details map.

  The default `fatal` value is derived from `SvPortSim.Protocol.fatal_runtime_error?/1`. Pass
  `fatal: true` or `fatal: false` to override the default.

  ## Examples

      iex> {:ok, error} = SvPortSim.Protocol.Command.error_response(1, "step", "unsupported_command", "unsupported command", %{})
      iex> {error["op"], error["body"]["fatal"]}
      {"step", false}

      iex> {:ok, error} = SvPortSim.Protocol.Command.error_response(1, "tick", "wrapper_fault", "segmentation fault", %{})
      iex> {error["op"], error["body"]["fatal"]}
      {"tick", true}
  """
  @spec error_response(term(), term(), term(), term(), term()) ::
          {:ok, envelope()} | {:error, term()}
  def error_response(id, command, code, message, details) do
    error_response(id, command, code, message, details, [])
  end

  @doc """
  Builds a validated error response envelope and explicitly configures `fatal`.

  ## Examples

      iex> {:ok, error} = SvPortSim.Protocol.Command.error_response(1, "tick", "invalid_state", "stopped", %{}, fatal: true)
      iex> error["body"]["fatal"]
      true
  """
  @spec error_response(term(), term(), term(), term(), term(), keyword()) ::
          {:ok, envelope()} | {:error, term()}
  def error_response(id, command, code, message, details, opts)
      when is_integer(id) and id >= 0 and is_binary(command) and byte_size(command) > 0 and
             is_binary(code) and is_binary(message) and is_map(details) and is_list(opts) do
    with {:ok, body} <- Protocol.error_body(code, message, details, opts),
         :ok <- validate_error_body(body) do
      {:ok,
       %{
         "v" => Protocol.version(),
         "id" => id,
         "kind" => "error",
         "op" => command,
         "body" => body
       }}
    end
  end

  def error_response(id, command, code, message, details, opts) do
    {:error, {:invalid_error_arguments, id, command, code, message, details, opts}}
  end

  @doc """
  Validates a request envelope and its command body.

  ## Examples

      iex> {:ok, request} = SvPortSim.Protocol.Command.request("tick", 1, %{"cycles" => 2})
      iex> SvPortSim.Protocol.Command.validate_request(request)
      :ok

      iex> SvPortSim.Protocol.Command.validate_request(%{"v" => 1, "id" => 1, "kind" => "request", "op" => "step", "body" => %{}})
      {:error, {:unsupported_command, "step"}}
  """
  @spec validate_request(term()) :: :ok | {:error, term()}
  def validate_request(%{} = message) do
    with :ok <- Protocol.validate_envelope(message),
         :ok <- validate_kind(message, "request") do
      validate_request_body(message["op"], message["body"])
    end
  end

  def validate_request(message), do: {:error, {:invalid_request, message}}

  @doc """
  Validates a successful response envelope and its command body.

  ## Examples

      iex> {:ok, response} = SvPortSim.Protocol.Command.ok_response(1, "shutdown", %{"status" => "closing"})
      iex> SvPortSim.Protocol.Command.validate_response(response)
      :ok
  """
  @spec validate_response(term()) :: :ok | {:error, term()}
  def validate_response(%{} = message) do
    with :ok <- Protocol.validate_envelope(message),
         :ok <- validate_kind(message, "response") do
      validate_response_body(message["op"], message["body"])
    end
  end

  def validate_response(message), do: {:error, {:invalid_response, message}}

  @doc """
  Validates an error response envelope and error body.

  Error responses may use an unsupported command name in `op`; this lets the wrapper explicitly
  answer a well-formed request whose operation is unknown.

  ## Examples

      iex> {:ok, error} = SvPortSim.Protocol.Command.error_response(1, "step", "unsupported_command", "unsupported command", %{})
      iex> SvPortSim.Protocol.Command.validate_error(error)
      :ok
  """
  @spec validate_error(term()) :: :ok | {:error, term()}
  def validate_error(%{} = message) do
    with :ok <- Protocol.validate_envelope(message),
         :ok <- validate_kind(message, "error") do
      validate_error_body(message["body"])
    end
  end

  def validate_error(message), do: {:error, {:invalid_error, message}}

  @doc """
  Validates any command-layer envelope by dispatching on `kind`.

  ## Examples

      iex> {:ok, request} = SvPortSim.Protocol.Command.request("metadata", 1)
      iex> SvPortSim.Protocol.Command.validate_message(request)
      :ok
  """
  @spec validate_message(term()) :: :ok | {:error, term()}
  def validate_message(%{"kind" => "request"} = message), do: validate_request(message)
  def validate_message(%{"kind" => "response"} = message), do: validate_response(message)
  def validate_message(%{"kind" => "error"} = message), do: validate_error(message)
  def validate_message(message), do: {:error, {:invalid_message, message}}

  @doc """
  Validates a request body for a command name.

  ## Examples

      iex> SvPortSim.Protocol.Command.validate_request_body("poke", %{"signal" => "enable", "value" => %{"bits" => "1", "width" => 1}})
      :ok

      iex> SvPortSim.Protocol.Command.validate_request_body("poke", %{"signal" => "enable"})
      {:error, {:missing_field, "poke", "value"}}
  """
  @spec validate_request_body(term(), term()) :: :ok | {:error, term()}
  def validate_request_body(command, body)
  def validate_request_body("metadata", body), do: validate_empty_body("metadata", body)

  def validate_request_body("reset", %{} = body) do
    with :ok <- validate_allowed_keys("reset", body, ~w(cycles reset)),
         :ok <- validate_optional_positive_integer("reset", body, "cycles") do
      validate_optional_non_empty_string("reset", body, "reset")
    end
  end

  def validate_request_body("eval", body), do: validate_empty_body("eval", body)

  def validate_request_body("poke", %{} = body) do
    with :ok <- validate_required_non_empty_string("poke", body, "signal"),
         :ok <- validate_required_encoded_value("poke", body, "value") do
      validate_allowed_keys("poke", body, ~w(signal value))
    end
  end

  def validate_request_body("tick", %{} = body) do
    with :ok <- validate_allowed_keys("tick", body, ~w(clock cycles)),
         :ok <- validate_optional_non_empty_string("tick", body, "clock") do
      validate_optional_positive_integer("tick", body, "cycles")
    end
  end

  def validate_request_body("cycle", %{} = body) do
    with :ok <- validate_required_positive_integer("cycle", body, "cycles"),
         :ok <- validate_optional_non_empty_string("cycle", body, "clock") do
      validate_allowed_keys("cycle", body, ~w(clock cycles))
    end
  end

  def validate_request_body("peek", %{} = body) do
    with :ok <- validate_required_non_empty_string("peek", body, "signal") do
      validate_allowed_keys("peek", body, ~w(signal))
    end
  end

  def validate_request_body("finish?", body), do: validate_empty_body("finish?", body)

  def validate_request_body("shutdown", body), do: validate_empty_body("shutdown", body)

  def validate_request_body(command, %{}) when is_binary(command) do
    {:error, {:unsupported_command, command}}
  end

  def validate_request_body(command, body), do: {:error, {:invalid_body, command, body}}

  @doc """
  Validates a successful response body for a command name.

  ## Examples

      iex> SvPortSim.Protocol.Command.validate_response_body("peek", %{"signal" => "count", "value" => %{"bits" => "0001", "width" => 4}, "cycle" => 3})
      :ok

      iex> SvPortSim.Protocol.Command.validate_response_body("shutdown", %{"status" => "closed"})
      {:error, {:invalid_field, "shutdown", "status", "closed"}}
  """
  @spec validate_response_body(term(), term()) :: :ok | {:error, term()}
  def validate_response_body(command, body)

  def validate_response_body("metadata", %{} = body) do
    with :ok <- validate_required_non_empty_string("metadata", body, "top"),
         :ok <- validate_required_list("metadata", body, "signals"),
         :ok <- validate_required_non_negative_integer("metadata", body, "cycle"),
         :ok <- validate_optional_map("metadata", body, "protocol") do
      validate_allowed_keys("metadata", body, ~w(top signals cycle protocol))
    end
  end

  def validate_response_body("reset", %{} = body) do
    with :ok <- validate_required_non_negative_integer("reset", body, "cycle"),
         :ok <- validate_required_map("reset", body, "reset"),
         :ok <- validate_required_positive_integer("reset", body["reset"], "cycles"),
         :ok <- validate_allowed_keys("reset", body, ~w(cycle reset)),
         :ok <- validate_allowed_keys("reset", body["reset"], ~w(cycles signal)) do
      validate_optional_non_empty_string("reset", body["reset"], "signal")
    end
  end

  def validate_response_body("eval", %{} = body) do
    with :ok <- validate_required_non_negative_integer("eval", body, "time"),
         :ok <- validate_required_non_negative_integer("eval", body, "cycle") do
      validate_allowed_keys("eval", body, ~w(time cycle))
    end
  end

  def validate_response_body("poke", %{} = body),
    do: validate_signal_value_cycle_body("poke", body)

  def validate_response_body("tick", %{} = body) do
    with :ok <- validate_required_non_empty_string("tick", body, "clock"),
         :ok <- validate_required_positive_integer("tick", body, "cycles"),
         :ok <- validate_required_non_negative_integer("tick", body, "cycle") do
      validate_allowed_keys("tick", body, ~w(clock cycles cycle))
    end
  end

  def validate_response_body("cycle", %{} = body) do
    with :ok <- validate_required_non_empty_string("cycle", body, "clock"),
         :ok <- validate_required_positive_integer("cycle", body, "cycles"),
         :ok <- validate_required_non_negative_integer("cycle", body, "cycle"),
         :ok <- validate_optional_non_negative_integer("cycle", body, "time") do
      validate_allowed_keys("cycle", body, ~w(clock cycles cycle time))
    end
  end

  def validate_response_body("peek", %{} = body),
    do: validate_signal_value_cycle_body("peek", body)

  def validate_response_body("finish?", %{} = body) do
    with :ok <- validate_required_boolean("finish?", body, "finished"),
         :ok <- validate_required_non_negative_integer("finish?", body, "time"),
         :ok <- validate_required_non_negative_integer("finish?", body, "cycle") do
      validate_allowed_keys("finish?", body, ~w(finished time cycle))
    end
  end

  def validate_response_body("shutdown", %{"status" => "closing"} = body) do
    validate_allowed_keys("shutdown", body, ~w(status))
  end

  def validate_response_body("shutdown", %{"status" => status}) do
    {:error, {:invalid_field, "shutdown", "status", status}}
  end

  def validate_response_body(command, %{}) when is_binary(command) do
    {:error, {:unsupported_command, command}}
  end

  def validate_response_body(command, body), do: {:error, {:invalid_body, command, body}}

  @doc """
  Validates the body of a command-layer error envelope.

  ## Examples

      iex> SvPortSim.Protocol.Command.validate_error_body(%{"code" => "invalid_request", "message" => "missing field", "details" => %{}, "fatal" => false})
      :ok

      iex> SvPortSim.Protocol.Command.validate_error_body(%{"code" => "invalid_request", "message" => "missing field"})
      :ok

      iex> SvPortSim.Protocol.Command.validate_error_body(%{"code" => "unsupported_feature", "message" => "structs are not supported", "details" => %{"feature" => "struct"}, "fatal" => false})
      :ok
  """
  @spec validate_error_body(term()) :: :ok | {:error, term()}
  def validate_error_body(body), do: Protocol.validate_error_body(body)

  defp validate_required_boolean(command, body, field) do
    case Map.fetch(body, field) do
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, value} -> {:error, {:invalid_field, command, field, value}}
      :error -> {:error, {:missing_field, command, field}}
    end
  end

  defp validate_optional_non_negative_integer(command, body, field) do
    case Map.fetch(body, field) do
      {:ok, value} when is_integer(value) and value >= 0 -> :ok
      {:ok, value} -> {:error, {:invalid_field, command, field, value}}
      :error -> :ok
    end
  end

  defp validate_kind(%{"kind" => actual}, expected) when actual == expected, do: :ok

  defp validate_kind(%{"kind" => actual}, expected),
    do: {:error, {:invalid_kind, actual, expected}}

  defp validate_kind(message, expected), do: {:error, {:missing_field, expected, "kind", message}}

  defp validate_empty_body(command, %{} = body) when map_size(body) == 0 do
    case command_spec(command) do
      {:ok, _spec} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp validate_empty_body(command, %{} = body) do
    case command_spec(command) do
      {:ok, _spec} -> validate_allowed_keys(command, body, [])
      {:error, _reason} = error -> error
    end
  end

  defp validate_empty_body(command, body), do: {:error, {:invalid_body, command, body}}

  defp validate_signal_value_cycle_body(command, body) do
    with :ok <- validate_required_non_empty_string(command, body, "signal"),
         :ok <- validate_required_encoded_value(command, body, "value"),
         :ok <- validate_required_non_negative_integer(command, body, "cycle") do
      validate_allowed_keys(command, body, ~w(signal value cycle))
    end
  end

  defp validate_allowed_keys(command, %{} = body, allowed_keys) do
    case Map.keys(body) -- allowed_keys do
      [] -> :ok
      [field | _rest] -> {:error, {:unknown_field, command, field}}
    end
  end

  defp validate_required_non_empty_string(command, body, field) do
    case Map.fetch(body, field) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> :ok
      {:ok, value} -> {:error, {:invalid_field, command, field, value}}
      :error -> {:error, {:missing_field, command, field}}
    end
  end

  defp validate_optional_non_empty_string(command, body, field) do
    case Map.fetch(body, field) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> :ok
      {:ok, value} -> {:error, {:invalid_field, command, field, value}}
      :error -> :ok
    end
  end

  defp validate_required_positive_integer(command, body, field) do
    case Map.fetch(body, field) do
      {:ok, value} when is_integer(value) and value > 0 -> :ok
      {:ok, value} -> {:error, {:invalid_field, command, field, value}}
      :error -> {:error, {:missing_field, command, field}}
    end
  end

  defp validate_optional_positive_integer(command, body, field) do
    case Map.fetch(body, field) do
      {:ok, value} when is_integer(value) and value > 0 -> :ok
      {:ok, value} -> {:error, {:invalid_field, command, field, value}}
      :error -> :ok
    end
  end

  defp validate_required_non_negative_integer(command, body, field) do
    case Map.fetch(body, field) do
      {:ok, value} when is_integer(value) and value >= 0 -> :ok
      {:ok, value} -> {:error, {:invalid_field, command, field, value}}
      :error -> {:error, {:missing_field, command, field}}
    end
  end

  defp validate_required_list(command, body, field) do
    case Map.fetch(body, field) do
      {:ok, value} when is_list(value) -> :ok
      {:ok, value} -> {:error, {:invalid_field, command, field, value}}
      :error -> {:error, {:missing_field, command, field}}
    end
  end

  defp validate_required_map(command, body, field) do
    case Map.fetch(body, field) do
      {:ok, value} when is_map(value) -> :ok
      {:ok, value} -> {:error, {:invalid_field, command, field, value}}
      :error -> {:error, {:missing_field, command, field}}
    end
  end

  defp validate_optional_map(command, body, field) do
    case Map.fetch(body, field) do
      {:ok, value} when is_map(value) -> :ok
      {:ok, value} -> {:error, {:invalid_field, command, field, value}}
      :error -> :ok
    end
  end

  defp validate_required_encoded_value(command, body, field) do
    case Map.fetch(body, field) do
      {:ok, value} -> validate_encoded_value(command, field, value)
      :error -> {:error, {:missing_field, command, field}}
    end
  end

  defp validate_encoded_value(command, field, %{"bits" => bits, "width" => width}) do
    validate_encoded_bits(command, field, bits, width)
  end

  defp validate_encoded_value(command, field, %{bits: bits, width: width}) do
    validate_encoded_bits(command, field, bits, width)
  end

  defp validate_encoded_value(command, field, value) do
    {:error, {:invalid_field, command, field, value}}
  end

  defp validate_encoded_bits(command, field, bits, width)
       when is_binary(bits) and is_integer(width) and width > 0 do
    cond do
      String.length(bits) != width ->
        {:error, {:invalid_encoded_width, command, field, bits, width}}

      not encoded_bit_string?(bits) ->
        {:error, {:invalid_encoded_bits, command, field, bits}}

      true ->
        :ok
    end
  end

  defp validate_encoded_bits(command, field, bits, width) do
    {:error, {:invalid_encoded_value, command, field, bits, width}}
  end

  defp encoded_bit_string?(bits) do
    bits
    |> String.graphemes()
    |> Enum.all?(&(&1 in ~w(0 1 x z)))
  end
end
