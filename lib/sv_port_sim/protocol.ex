defmodule SvPortSim.Protocol do
  @moduledoc """
  Runtime wire-format contract for communication between Elixir and the C++ wrapper process.

  ## MVP wire format

  SvPortSim protocol v1 uses a 4-byte big-endian length-prefixed frame followed by a UTF-8 JSON payload.

      frame = uint32_be(payload_length) <> payload
      payload = UTF-8 JSON object

  The payload is a JSON object with this common envelope:

      {
        "v": 1,
        "id": 1,
        "kind": "request",
        "op": "hello",
        "body": {}
      }

  JSON object member order is not significant.

  ## Port framing

  Elixir code should open the wrapper port with:

      [:binary, {:packet, 4}, :exit_status]

  With `{:packet, 4}`, Elixir sends and receives the JSON payload bytes. The BEAM adds the
  4-byte length prefix on writes and strips it on reads. The C++ wrapper must read and write
  the 4-byte big-endian length prefix explicitly.

  ## Limits

  The maximum JSON payload size is 1 MiB. A zero-length payload is invalid. A payload larger
  than the maximum size is a fatal protocol error.

  ## Runtime errors, timeouts, and simulator exits

  Runtime calls expose exactly two Elixir return shapes:

    * `{:ok, body}` for a successful wrapper response envelope with `kind: "response"`
    * `{:error, error_body}` for wrapper-side errors and Elixir-side runtime failures

  The canonical runtime error body is a JSON object with string keys:

      {
        "code": "invalid_signal",
        "message": "signal is not readable",
        "details": {"signal": "enable"},
        "fatal": false
      }

  Non-fatal errors are ordinary command failures. The wrapper must emit one `kind: "error"`
  envelope with the same request `id` and `op`, keep the simulator process running, and accept
  the next request. Non-fatal codes are `"invalid_command"`, `"unsupported_command"`,
  `"invalid_request"`, `"invalid_signal"`, `"invalid_value"`, `"invalid_state"`, and
  `"unsupported_feature"`.

  Fatal errors make the current simulator process unusable. The Elixir side must close the
  port, discard pending state, and require the caller to start a new simulator before retrying.
  Fatal codes are `"protocol_error"`, `"timeout"`, `"malformed_output"`,
  `"simulator_exit"`, `"simulator_failure"`, `"port_closed"`, and `"wrapper_fault"`.

  Elixir calls default to `5_000` milliseconds. A caller may configure a positive
  integer timeout in milliseconds or `:infinity`. A timeout is fatal because a late wrapper
  response can no longer be safely matched to the synchronous request stream.

  If the simulator process exits, crashes, closes its port, closes stdout/stderr, or returns
  malformed output, Elixir reports a fatal runtime error and does not reuse that process.
  Unsupported SystemVerilog/runtime features are reported with `"unsupported_feature"` and are
  non-fatal when the wrapper can still identify the request.

  ## Examples

  The MVP protocol version is `1`.

      iex> SvPortSim.Protocol.version()
      1

  The maximum payload size is 1 MiB.

      iex> SvPortSim.Protocol.max_payload_size()
      1_048_576

  The recommended Elixir port options use binary mode and 4-byte packet framing.

      iex> SvPortSim.Protocol.port_options()
      [:binary, {:packet, 4}, :exit_status]

  A valid envelope can be encoded to JSON payload bytes and decoded back.

      iex> message = %{
      ...>   "v" => 1,
      ...>   "id" => 1,
      ...>   "kind" => "request",
      ...>   "op" => "hello",
      ...>   "body" => %{"client" => "sv_port_sim"}
      ...> }
      iex> {:ok, payload} = SvPortSim.Protocol.encode_payload(message)
      iex> is_binary(payload)
      true
      iex> SvPortSim.Protocol.decode_payload(payload) == {:ok, message}
      true

  A full wire frame is a 4-byte big-endian length prefix followed by the JSON payload bytes.

      iex> payload = ~s({"v":1,"id":1,"kind":"request","op":"hello","body":{"client":"sv_port_sim"}})
      iex> byte_size(payload)
      76
      iex> {:ok, frame} = SvPortSim.Protocol.frame_payload(payload)
      iex> <<length::32, rest::binary>> = frame
      iex> {length, rest == payload}
      {76, true}

  A zero-length payload is rejected.

      iex> SvPortSim.Protocol.frame_payload("")
      {:error, :empty_payload}

  An unsupported protocol version is rejected.

      iex> SvPortSim.Protocol.validate_envelope(%{
      ...>   "v" => 2,
      ...>   "id" => 1,
      ...>   "kind" => "request",
      ...>   "op" => "hello",
      ...>   "body" => %{}
      ...> })
      {:error, {:unsupported_version, 2, 1}}

  Malformed JSON payloads are rejected.

      iex> match?({:error, {:json_decode_failed, _}}, SvPortSim.Protocol.decode_payload("{"))
      true

  Normal runtime errors are non-fatal.

      iex> {:ok, error} = SvPortSim.Protocol.error_body("invalid_signal", "unknown signal", %{"signal" => "missing"})
      iex> {error["code"], error["fatal"]}
      {"invalid_signal", false}

  Fatal runtime failures map to `{:error, error_body}` and require a new simulator process.

      iex> {:error, timeout} = SvPortSim.Protocol.runtime_failure({:timeout, 7, "tick", 5_000})
      iex> {timeout["code"], timeout["details"]["id"], timeout["fatal"]}
      {"timeout", 7, true}

  Unsupported features have explicit, non-fatal semantics.

      iex> {:error, unsupported} = SvPortSim.Protocol.runtime_failure(:unsupported_feature, %{"feature" => "struct"})
      iex> {unsupported["code"], unsupported["fatal"]}
      {"unsupported_feature", false}

  ## Rationale

  The MVP uses length-prefixed JSON rather than line-based JSON so frame boundaries and
  message-size limits are explicit. It avoids committing to a bespoke binary command schema
  before the command protocol, signal metadata schema, and supported SystemVerilog data subset
  are finalized.
  """

  @version 1
  @max_payload_size 1_048_576
  @default_timeout 5_000
  @kinds ~w(request response error)

  @normal_runtime_error_codes ~w(
    invalid_command
    unsupported_command
    invalid_request
    invalid_signal
    invalid_value
    invalid_state
    unsupported_feature
  )

  @fatal_runtime_error_codes ~w(
    protocol_error
    timeout
    malformed_output
    simulator_exit
    simulator_failure
    port_closed
    wrapper_fault
  )

  @runtime_error_codes @normal_runtime_error_codes ++ @fatal_runtime_error_codes

  @failure_mappings [
    %{
      failure: :protocol_error,
      code: "protocol_error",
      message: "protocol error",
      fatal: true,
      cleanup: :close_port,
      retry: :new_simulator
    },
    %{
      failure: :invalid_command,
      code: "invalid_command",
      message: "invalid command",
      fatal: false,
      cleanup: :keep_running,
      retry: :retry_after_fix
    },
    %{
      failure: :unsupported_command,
      code: "unsupported_command",
      message: "unsupported command",
      fatal: false,
      cleanup: :keep_running,
      retry: :retry_after_fix
    },
    %{
      failure: :invalid_request,
      code: "invalid_request",
      message: "invalid request",
      fatal: false,
      cleanup: :keep_running,
      retry: :retry_after_fix
    },
    %{
      failure: :invalid_signal,
      code: "invalid_signal",
      message: "invalid signal",
      fatal: false,
      cleanup: :keep_running,
      retry: :retry_after_fix
    },
    %{
      failure: :invalid_value,
      code: "invalid_value",
      message: "invalid value",
      fatal: false,
      cleanup: :keep_running,
      retry: :retry_after_fix
    },
    %{
      failure: :invalid_state,
      code: "invalid_state",
      message: "invalid simulator state",
      fatal: false,
      cleanup: :keep_running,
      retry: :retry_after_fix
    },
    %{
      failure: :unsupported_feature,
      code: "unsupported_feature",
      message: "unsupported feature",
      fatal: false,
      cleanup: :keep_running,
      retry: :retry_after_fix
    },
    %{
      failure: :timeout,
      code: "timeout",
      message: "simulator response timed out",
      fatal: true,
      cleanup: :close_port,
      retry: :new_simulator
    },
    %{
      failure: :malformed_output,
      code: "malformed_output",
      message: "simulator returned malformed output",
      fatal: true,
      cleanup: :close_port,
      retry: :new_simulator
    },
    %{
      failure: :simulator_exit,
      code: "simulator_exit",
      message: "simulator process exited",
      fatal: true,
      cleanup: :close_port,
      retry: :new_simulator
    },
    %{
      failure: :simulator_failure,
      code: "simulator_failure",
      message: "simulator process failed",
      fatal: true,
      cleanup: :close_port,
      retry: :new_simulator
    },
    %{
      failure: :port_closed,
      code: "port_closed",
      message: "simulator port closed",
      fatal: true,
      cleanup: :close_port,
      retry: :new_simulator
    },
    %{
      failure: :wrapper_fault,
      code: "wrapper_fault",
      message: "wrapper fault",
      fatal: true,
      cleanup: :close_port,
      retry: :new_simulator
    }
  ]

  @type version :: 1
  @type request_id :: non_neg_integer()
  @type kind :: String.t()
  @type operation :: String.t()
  @type timeout_ms :: pos_integer() | :infinity
  @type envelope :: %{required(String.t()) => term()}
  @type runtime_error_code :: String.t()
  @type runtime_failure_name :: atom()
  @type error_body :: %{required(String.t()) => term()}
  @type failure_mapping :: %{
          required(:failure) => runtime_failure_name(),
          required(:code) => runtime_error_code(),
          required(:message) => String.t(),
          required(:fatal) => boolean(),
          required(:cleanup) => :keep_running | :close_port,
          required(:retry) => :retry_after_fix | :new_simulator
        }

  @doc """
  Returns the MVP protocol version.

  ## Examples

      iex> SvPortSim.Protocol.version()
      1
  """
  @spec version() :: version()
  def version(), do: @version

  @doc """
  Returns the maximum JSON payload size in bytes.

  ## Examples

      iex> SvPortSim.Protocol.max_payload_size()
      1_048_576
  """
  @spec max_payload_size() :: pos_integer()
  def max_payload_size(), do: @max_payload_size

  @doc """
  Returns the default Elixir runtime call timeout in milliseconds.

  ## Examples

      iex> SvPortSim.Protocol.default_timeout()
      5_000
  """
  @spec default_timeout() :: pos_integer()
  def default_timeout(), do: @default_timeout

  @doc """
  Normalizes timeout configuration for runtime calls.

  Accepts a positive integer timeout in milliseconds, `:infinity`, or a keyword list with a
  `:timeout` entry. An empty keyword list uses `default_timeout/0`.

  ## Examples

      iex> SvPortSim.Protocol.normalize_timeout([])
      {:ok, 5_000}

      iex> SvPortSim.Protocol.normalize_timeout(timeout: 250)
      {:ok, 250}

      iex> SvPortSim.Protocol.normalize_timeout(:infinity)
      {:ok, :infinity}

      iex> SvPortSim.Protocol.normalize_timeout(timeout: 0)
      {:error, {:invalid_timeout, 0}}
  """
  @spec normalize_timeout(keyword() | timeout_ms() | term()) ::
          {:ok, timeout_ms()} | {:error, term()}
  def normalize_timeout(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts
      |> Keyword.get(:timeout, @default_timeout)
      |> normalize_timeout()
    else
      {:error, {:invalid_timeout_options, opts}}
    end
  end

  def normalize_timeout(:infinity), do: {:ok, :infinity}
  def normalize_timeout(timeout) when is_integer(timeout) and timeout > 0, do: {:ok, timeout}
  def normalize_timeout(timeout), do: {:error, {:invalid_timeout, timeout}}

  @doc """
  Returns the recommended Elixir port options for the MVP wire format.

  ## Examples

      iex> SvPortSim.Protocol.port_options()
      [:binary, {:packet, 4}, :exit_status]
  """
  @spec port_options() :: [:binary | :exit_status | {:packet, 4}]
  def port_options(), do: [:binary, {:packet, 4}, :exit_status]

  @doc """
  Returns all canonical runtime error codes.

  ## Examples

      iex> "unsupported_feature" in SvPortSim.Protocol.runtime_error_codes()
      true

      iex> "timeout" in SvPortSim.Protocol.runtime_error_codes()
      true
  """
  @spec runtime_error_codes() :: [runtime_error_code()]
  def runtime_error_codes(), do: @runtime_error_codes

  @doc """
  Returns runtime error codes that keep the current simulator process usable.

  ## Examples

      iex> SvPortSim.Protocol.normal_runtime_error_codes() |> Enum.member?("invalid_signal")
      true
  """
  @spec normal_runtime_error_codes() :: [runtime_error_code()]
  def normal_runtime_error_codes(), do: @normal_runtime_error_codes

  @doc """
  Returns runtime error codes that make the current simulator process unusable.

  ## Examples

      iex> SvPortSim.Protocol.fatal_runtime_error_codes() |> Enum.member?("malformed_output")
      true
  """
  @spec fatal_runtime_error_codes() :: [runtime_error_code()]
  def fatal_runtime_error_codes(), do: @fatal_runtime_error_codes

  @doc """
  Returns whether `code` is fatal by default.

  ## Examples

      iex> SvPortSim.Protocol.fatal_runtime_error?("timeout")
      true

      iex> SvPortSim.Protocol.fatal_runtime_error?("invalid_value")
      false
  """
  @spec fatal_runtime_error?(term()) :: boolean()
  def fatal_runtime_error?(code) when is_binary(code), do: code in @fatal_runtime_error_codes
  def fatal_runtime_error?(_code), do: false

  @doc """
  Returns the runtime failure-to-return-value mapping table.

  Each entry fixes the canonical error code, default fatality, cleanup action, and retry
  expectation for one wrapper-side or Elixir-side failure.

  ## Examples

      iex> SvPortSim.Protocol.failure_mappings() |> Enum.map(& &1.failure) |> Enum.member?(:timeout)
      true
  """
  @spec failure_mappings() :: [failure_mapping()]
  def failure_mappings(), do: @failure_mappings

  @doc """
  Looks up one runtime failure mapping.

  ## Examples

      iex> mapping = SvPortSim.Protocol.failure_mapping(:timeout)
      iex> {mapping.code, mapping.fatal, mapping.cleanup, mapping.retry}
      {"timeout", true, :close_port, :new_simulator}

      iex> mapping = SvPortSim.Protocol.failure_mapping(:invalid_signal)
      iex> {mapping.code, mapping.fatal, mapping.cleanup, mapping.retry}
      {"invalid_signal", false, :keep_running, :retry_after_fix}

      iex> SvPortSim.Protocol.failure_mapping(:not_a_failure)
      {:error, {:unknown_runtime_failure, :not_a_failure}}
  """
  @spec failure_mapping(term()) :: failure_mapping() | {:error, term()}
  def failure_mapping(failure) when is_atom(failure) do
    case Enum.find(@failure_mappings, &(&1.failure == failure)) do
      nil -> {:error, {:unknown_runtime_failure, failure}}
      mapping -> mapping
    end
  end

  def failure_mapping(failure), do: {:error, {:unknown_runtime_failure, failure}}

  @doc """
  Builds a canonical runtime error body.

  The default `"fatal"` value is derived from the error code. Pass `fatal: true` or
  `fatal: false` to override the default when a wrapper has more specific information.

  ## Examples

      iex> {:ok, body} = SvPortSim.Protocol.error_body("invalid_signal", "unknown signal", %{"signal" => "count"})
      iex> {body["code"], body["details"]["signal"], body["fatal"]}
      {"invalid_signal", "count", false}

      iex> {:ok, body} = SvPortSim.Protocol.error_body("wrapper_fault", "segmentation fault", %{})
      iex> {body["code"], body["fatal"]}
      {"wrapper_fault", true}

      iex> SvPortSim.Protocol.error_body("bad_code", "bad", %{})
      {:error, {:invalid_error_code, "bad_code"}}
  """
  @spec error_body(term(), term(), map(), keyword()) :: {:ok, error_body()} | {:error, term()}
  def error_body(code, message, details \\ %{}, opts \\ [])

  def error_body(code, message, details, opts)
      when is_binary(code) and is_binary(message) and is_map(details) and is_list(opts) do
    with :ok <- validate_error_code(code),
         :ok <- validate_non_empty_message(message),
         {:ok, fatal} <- fatal_from_options(code, opts) do
      {:ok,
       %{
         "code" => code,
         "message" => message,
         "details" => details,
         "fatal" => fatal
       }}
    end
  end

  def error_body(code, message, details, opts) do
    {:error, {:invalid_error_arguments, code, message, details, opts}}
  end

  @doc """
  Validates a runtime error body.

  `"details"` and `"fatal"` are optional for backward compatibility with early command-layer
  drafts. Use `normalize_error_body/1` to obtain the canonical shape with both fields present.

  ## Examples

      iex> SvPortSim.Protocol.validate_error_body(%{"code" => "invalid_request", "message" => "missing field", "details" => %{}, "fatal" => false})
      :ok

      iex> SvPortSim.Protocol.validate_error_body(%{"code" => "invalid_request", "message" => "missing field"})
      :ok

      iex> SvPortSim.Protocol.validate_error_body(%{"code" => "invalid_request", "message" => "missing field", "fatal" => "no"})
      {:error, {:invalid_field, "error", "fatal", "no"}}
  """
  @spec validate_error_body(term()) :: :ok | {:error, term()}
  def validate_error_body(%{} = body) do
    with :ok <- validate_required_error_code(body),
         :ok <- validate_required_non_empty_string("error", body, "message"),
         :ok <- validate_optional_map("error", body, "details"),
         :ok <- validate_optional_boolean("error", body, "fatal") do
      validate_allowed_keys("error", body, ~w(code message details fatal))
    end
  end

  def validate_error_body(body), do: {:error, {:invalid_error_body, body}}

  @doc """
  Normalizes a valid runtime error body to the canonical shape.

  Missing `"details"` becomes `%{}`. Missing `"fatal"` is derived from the error code.

  ## Examples

      iex> {:ok, body} = SvPortSim.Protocol.normalize_error_body(%{"code" => "timeout", "message" => "slow"})
      iex> {body["details"], body["fatal"]}
      {%{}, true}
  """
  @spec normalize_error_body(term()) :: {:ok, error_body()} | {:error, term()}
  def normalize_error_body(%{} = body) do
    with :ok <- validate_error_body(body) do
      code = body["code"]

      {:ok,
       body
       |> Map.put("details", Map.get(body, "details", %{}))
       |> Map.put("fatal", Map.get(body, "fatal", fatal_runtime_error?(code)))}
    end
  end

  def normalize_error_body(body), do: {:error, {:invalid_error_body, body}}

  @doc """
  Maps a decoded wrapper envelope into the Elixir public return contract.

  Successful responses become `{:ok, body}`. Error envelopes become `{:error, error_body}`.
  Malformed envelopes become a fatal `"malformed_output"` error.

  ## Examples

      iex> SvPortSim.Protocol.to_elixir_return(%{"kind" => "response", "body" => %{"cycle" => 1}})
      {:ok, %{"cycle" => 1}}

      iex> {:ok, error} = SvPortSim.Protocol.error_body("invalid_value", "bad value", %{"signal" => "d"})
      iex> {:error, returned} = SvPortSim.Protocol.to_elixir_return(%{"kind" => "error", "body" => error})
      iex> {returned["code"], returned["fatal"]}
      {"invalid_value", false}

      iex> {:error, returned} = SvPortSim.Protocol.to_elixir_return(%{"kind" => "response", "body" => "not an object"})
      iex> {returned["code"], returned["fatal"]}
      {"malformed_output", true}
  """
  @spec to_elixir_return(term()) :: {:ok, map()} | {:error, error_body()}
  def to_elixir_return(%{"kind" => "response", "body" => body}) when is_map(body), do: {:ok, body}

  def to_elixir_return(%{"kind" => "error", "body" => body}) do
    case normalize_error_body(body) do
      {:ok, error} -> {:error, error}
      {:error, reason} -> runtime_failure(:malformed_output, %{"reason" => inspect(reason)})
    end
  end

  def to_elixir_return(%{} = message) do
    runtime_failure(:malformed_output, %{"message" => inspect(message)})
  end

  def to_elixir_return(output) do
    runtime_failure(:malformed_output, %{"output" => inspect(output)})
  end

  @doc """
  Maps an Elixir-side or wrapper-side runtime failure to `{:error, error_body}`.

  The returned error body is canonical and includes `"details"` and `"fatal"`.

  ## Examples

      iex> {:error, body} = SvPortSim.Protocol.runtime_failure(:port_closed, %{"stream" => "stdout"})
      iex> {body["code"], body["details"]["stream"], body["fatal"]}
      {"port_closed", "stdout", true}

      iex> {:error, body} = SvPortSim.Protocol.runtime_failure({:exit_status, 1})
      iex> {body["code"], body["details"]["status"], body["fatal"]}
      {"simulator_exit", 1, true}
  """
  @spec runtime_failure(term(), map()) :: {:error, error_body()} | {:error, term()}
  def runtime_failure(failure, details \\ %{})

  def runtime_failure({:timeout, id, op, timeout}, details) when is_map(details) do
    details =
      details
      |> Map.put_new("id", id)
      |> Map.put_new("op", op)
      |> Map.put_new("timeout_ms", timeout)

    runtime_failure(:timeout, details)
  end

  def runtime_failure({:exit_status, status}, details) when is_map(details) do
    runtime_failure(:simulator_exit, Map.put_new(details, "status", status))
  end

  def runtime_failure({:port_closed, stream}, details) when is_map(details) do
    runtime_failure(:port_closed, Map.put_new(details, "stream", to_string(stream)))
  end

  def runtime_failure({:malformed_output, output}, details) when is_map(details) do
    runtime_failure(:malformed_output, Map.put_new(details, "output", inspect(output)))
  end

  def runtime_failure({:wrapper_fault, reason}, details) when is_map(details) do
    runtime_failure(:wrapper_fault, Map.put_new(details, "reason", inspect(reason)))
  end

  def runtime_failure({:simulator_failure, reason}, details) when is_map(details) do
    runtime_failure(:simulator_failure, Map.put_new(details, "reason", inspect(reason)))
  end

  def runtime_failure(failure, details) when is_atom(failure) and is_map(details) do
    case failure_mapping(failure) do
      %{code: code, message: message, fatal: fatal} ->
        case error_body(code, message, details, fatal: fatal) do
          {:ok, body} -> {:error, body}
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  def runtime_failure(failure, details),
    do: {:error, {:invalid_runtime_failure, failure, details}}

  @doc """
  Encodes a protocol envelope into JSON payload bytes.

  This returns the payload only. When using `{:packet, 4}`, do not manually prepend the length
  prefix before passing data to `Port.command/2`.

  ## Examples

      iex> message = %{
      ...>   "v" => 1,
      ...>   "id" => 1,
      ...>   "kind" => "request",
      ...>   "op" => "hello",
      ...>   "body" => %{"client" => "sv_port_sim"}
      ...> }
      iex> {:ok, payload} = SvPortSim.Protocol.encode_payload(message)
      iex> SvPortSim.Protocol.decode_payload(payload) == {:ok, message}
      true
  """
  @spec encode_payload(envelope()) :: {:ok, binary()} | {:error, term()}
  def encode_payload(message) when is_map(message) do
    with :ok <- validate_envelope(message) do
      payload = JSON.encode!(message)

      with :ok <- validate_payload_size(payload) do
        {:ok, payload}
      end
    end
  rescue
    exception -> {:error, {:json_encode_failed, Exception.message(exception)}}
  end

  def encode_payload(message), do: {:error, {:invalid_envelope, message}}

  @doc """
  Decodes JSON payload bytes into a protocol envelope.

  ## Examples

      iex> payload = ~s({"v":1,"id":1,"kind":"request","op":"hello","body":{}})
      iex> SvPortSim.Protocol.decode_payload(payload)
      {:ok, %{"body" => %{}, "id" => 1, "kind" => "request", "op" => "hello", "v" => 1}}

      iex> match?({:error, {:json_decode_failed, _}}, SvPortSim.Protocol.decode_payload("{"))
      true
  """
  @spec decode_payload(binary()) :: {:ok, envelope()} | {:error, term()}
  def decode_payload(payload) when is_binary(payload) do
    with :ok <- validate_payload_size(payload),
         {:ok, decoded} <- decode_json(payload),
         :ok <- validate_envelope(decoded) do
      {:ok, decoded}
    end
  end

  def decode_payload(payload), do: {:error, {:invalid_payload, payload}}

  @doc """
  Builds a full wire frame for documentation and low-level tests.

  In normal Elixir port usage with `{:packet, 4}`, callers should send only the JSON payload.
  This helper exists to pin the externally visible frame format.

  ## Examples

      iex> payload = ~s({"v":1,"id":1,"kind":"request","op":"hello","body":{"client":"sv_port_sim"}})
      iex> {:ok, frame} = SvPortSim.Protocol.frame_payload(payload)
      iex> <<length::32, rest::binary>> = frame
      iex> {length, rest == payload}
      {76, true}

      iex> SvPortSim.Protocol.frame_payload("")
      {:error, :empty_payload}
  """
  @spec frame_payload(binary()) :: {:ok, binary()} | {:error, term()}
  def frame_payload(payload) when is_binary(payload) do
    with :ok <- validate_payload_size(payload) do
      {:ok, <<byte_size(payload)::32, payload::binary>>}
    end
  end

  def frame_payload(payload), do: {:error, {:invalid_payload, payload}}

  @doc """
  Validates the common protocol envelope.

  ## Examples

      iex> SvPortSim.Protocol.validate_envelope(%{
      ...>   "v" => 1,
      ...>   "id" => 1,
      ...>   "kind" => "request",
      ...>   "op" => "hello",
      ...>   "body" => %{}
      ...> })
      :ok

      iex> SvPortSim.Protocol.validate_envelope(%{
      ...>   "v" => 2,
      ...>   "id" => 1,
      ...>   "kind" => "request",
      ...>   "op" => "hello",
      ...>   "body" => %{}
      ...> })
      {:error, {:unsupported_version, 2, 1}}

      iex> SvPortSim.Protocol.validate_envelope(%{
      ...>   "v" => 1,
      ...>   "id" => 1,
      ...>   "kind" => "command",
      ...>   "op" => "hello",
      ...>   "body" => %{}
      ...> })
      {:error, {:invalid_kind, "command"}}
  """
  @spec validate_envelope(term()) :: :ok | {:error, term()}
  def validate_envelope(%{
        "v" => @version,
        "id" => id,
        "kind" => kind,
        "op" => op,
        "body" => body
      })
      when is_integer(id) and id >= 0 and is_binary(kind) and is_binary(op) and is_map(body) do
    cond do
      kind not in @kinds -> {:error, {:invalid_kind, kind}}
      byte_size(op) == 0 -> {:error, :empty_operation}
      true -> :ok
    end
  end

  def validate_envelope(%{"v" => version}) when is_integer(version) do
    {:error, {:unsupported_version, version, @version}}
  end

  def validate_envelope(message), do: {:error, {:invalid_envelope, message}}

  defp validate_payload_size(payload) do
    size = byte_size(payload)

    cond do
      size == 0 -> {:error, :empty_payload}
      size > @max_payload_size -> {:error, {:payload_too_large, size, @max_payload_size}}
      true -> :ok
    end
  end

  defp decode_json(payload) do
    case JSON.decode(payload) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:json_decode_failed, reason}}
    end
  end

  defp validate_error_code(code) when code in @runtime_error_codes, do: :ok
  defp validate_error_code(code), do: {:error, {:invalid_error_code, code}}

  defp validate_non_empty_message(message) when byte_size(message) > 0, do: :ok

  defp validate_non_empty_message(message),
    do: {:error, {:invalid_field, "error", "message", message}}

  defp fatal_from_options(code, opts) do
    if Keyword.keyword?(opts) do
      case Keyword.fetch(opts, :fatal) do
        :error -> {:ok, fatal_runtime_error?(code)}
        {:ok, fatal} when is_boolean(fatal) -> {:ok, fatal}
        {:ok, fatal} -> {:error, {:invalid_fatal, fatal}}
      end
    else
      {:error, {:invalid_error_options, opts}}
    end
  end

  defp validate_required_error_code(body) do
    case Map.fetch(body, "code") do
      {:ok, code} when code in @runtime_error_codes -> :ok
      {:ok, code} -> {:error, {:invalid_error_code, code, @runtime_error_codes}}
      :error -> {:error, {:missing_field, "error", "code"}}
    end
  end

  defp validate_required_non_empty_string(command, body, field) do
    case Map.fetch(body, field) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> :ok
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

  defp validate_optional_boolean(command, body, field) do
    case Map.fetch(body, field) do
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, value} -> {:error, {:invalid_field, command, field, value}}
      :error -> :ok
    end
  end

  defp validate_allowed_keys(command, %{} = body, allowed_keys) do
    case Map.keys(body) -- allowed_keys do
      [] -> :ok
      [field | _rest] -> {:error, {:unknown_field, command, field}}
    end
  end
end
