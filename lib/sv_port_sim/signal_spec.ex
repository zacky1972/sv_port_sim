defmodule SvPortSim.SignalSpec do
  @moduledoc """
  Defines the metadata schema for SystemVerilog ports exposed to Elixir.

  The C++ wrapper emits one signal specification for each Verilated top-level
  port in the `metadata` command response. The schema is JSON-compatible and
  therefore uses string keys in its canonical form:

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

  Required fields:

    * `"name"` - a simple SystemVerilog identifier exposed through the runtime
      protocol.
    * `"direction"` - one of `"input"`, `"output"`, or `"inout"`.
    * `"type"` - the supported base type, currently `"bit"` or `"logic"`.
    * `"width"` - the canonical runtime width in bits.
    * `"signed"` - whether the value has a signed numeric interpretation.
    * `"packed"` - scalar metadata or one canonical packed-vector dimension.
    * `"role"` - `"data"`, `"clock"`, or `"reset"` metadata.

  The wrapper must canonicalise every supported vector as `[width - 1:0]` before
  emitting metadata. Elixir consumes the list with `normalize_many/1`, finds
  signals with `lookup/2`, and checks command legality with `validate_poke/2`
  and `validate_peek/1` before sending runtime requests.

  Unsupported or ambiguous shapes are rejected rather than guessed. This MVP
  excludes escaped identifiers, unpacked arrays, multi-dimensional packed arrays,
  structs, unions, interfaces, real-valued ports, implicit widths, and
  non-canonical packed ranges.

  ## Examples

  The schema is versioned so the wrapper and Elixir side can negotiate future
  changes explicitly.

      iex> SvPortSim.SignalSpec.schema_version()
      1

  A small module with a clock, active-low reset, scalar input, output vector,
  and signed input vector can be represented as JSON-compatible maps.

      iex> specs = SvPortSim.SignalSpec.example_specs()
      iex> Enum.map(specs, & &1["name"])
      ["clk", "rst_n", "enable", "count", "delta"]
      iex> SvPortSim.SignalSpec.validate_many(specs)
      :ok

  Clock and reset roles are explicit.

      iex> {:ok, clk} = SvPortSim.SignalSpec.lookup(SvPortSim.SignalSpec.example_specs(), "clk")
      iex> {clk["role"]["kind"], clk["role"]["edge"]}
      {"clock", "posedge"}
      iex> {:ok, rst} = SvPortSim.SignalSpec.lookup(SvPortSim.SignalSpec.example_specs(), "rst_n")
      iex> {rst["role"]["kind"], rst["role"]["active"]}
      {"reset", "low"}

  Direction metadata is sufficient for the Elixir side to reject illegal pokes
  and peeks before the request is sent to the wrapper.

      iex> enable = SvPortSim.SignalSpec.data("enable", "input", "bit", 1)
      iex> SvPortSim.SignalSpec.validate_poke(enable, %{"bits" => "1", "width" => 1})
      :ok
      iex> SvPortSim.SignalSpec.validate_peek(enable)
      {:error, {:not_readable, "enable", "input"}}
      iex> count = SvPortSim.SignalSpec.data("count", "output", "logic", 8)
      iex> SvPortSim.SignalSpec.validate_peek(count)
      :ok
      iex> SvPortSim.SignalSpec.validate_poke(count, %{"bits" => "00000000", "width" => 8})
      {:error, {:not_writable, "count", "output"}}

  Non-canonical packed-vector ranges are rejected because bit ordering would be
  ambiguous for runtime values.

      iex> spec = SvPortSim.SignalSpec.data("count", "output", "logic", 8)
      iex> spec = put_in(spec, ["packed", "dimensions"], [%{"left" => 0, "right" => 7}])
      iex> SvPortSim.SignalSpec.validate(spec)
      {:error, {:unsupported_packed_range, %{"left" => 0, "right" => 7}, :canonical_range_required}}
  """

  alias SvPortSim.Protocol.DataType

  @schema_version 1
  @directions ~w(input output inout)
  @readable_directions ~w(output inout)
  @writable_directions ~w(input inout)
  @types ~w(bit logic)
  @role_kinds ~w(data clock reset)
  @clock_edges ~w(posedge negedge)
  @reset_active_levels ~w(high low)
  @top_level_keys ~w(name direction type width signed packed role)
  @scalar_packed %{"kind" => "scalar", "dimensions" => []}
  @sv_identifier ~r/\A[A-Za-z_][A-Za-z0-9_$]*\z/

  @type direction :: String.t()
  @type base_type :: String.t()
  @type role_kind :: String.t()
  @type t :: %{required(String.t()) => term()}

  @doc """
  Returns the SignalSpec schema version.

  ## Examples

      iex> SvPortSim.SignalSpec.schema_version()
      1
  """
  @spec schema_version() :: pos_integer()
  def schema_version(), do: @schema_version

  @doc """
  Returns the maximum supported signal width.

  ## Examples

      iex> SvPortSim.SignalSpec.max_width()
      4096
  """
  @spec max_width() :: pos_integer()
  def max_width(), do: DataType.max_vector_width()

  @doc """
  Returns a machine-readable summary of the schema.

  ## Examples

      iex> schema = SvPortSim.SignalSpec.schema()
      iex> schema["directions"]
      ["input", "output", "inout"]
      iex> schema["roles"]
      ["data", "clock", "reset"]
  """
  @spec schema() :: map()
  def schema() do
    %{
      "version" => schema_version(),
      "required" => @top_level_keys,
      "directions" => @directions,
      "types" => @types,
      "roles" => @role_kinds,
      "clock_edges" => @clock_edges,
      "reset_active_levels" => @reset_active_levels,
      "max_width" => max_width(),
      "packed" => %{
        "scalar" => @scalar_packed,
        "packed_vector" => %{
          "kind" => "packed_vector",
          "dimensions" => [%{"left" => "width - 1", "right" => 0}]
        }
      }
    }
  end

  @doc """
  Returns the accepted port directions.

  ## Examples

      iex> SvPortSim.SignalSpec.directions()
      ["input", "output", "inout"]
  """
  @spec directions() :: [direction()]
  def directions(), do: @directions

  @doc """
  Returns the accepted base types.

  ## Examples

      iex> SvPortSim.SignalSpec.types()
      ["bit", "logic"]
  """
  @spec types() :: [base_type()]
  def types(), do: @types

  @doc """
  Returns the accepted signal role kinds.

  ## Examples

      iex> SvPortSim.SignalSpec.role_kinds()
      ["data", "clock", "reset"]
  """
  @spec role_kinds() :: [role_kind()]
  def role_kinds(), do: @role_kinds

  @doc """
  Returns the accepted clock edges.

  ## Examples

      iex> SvPortSim.SignalSpec.clock_edges()
      ["posedge", "negedge"]
  """
  @spec clock_edges() :: [String.t()]
  def clock_edges(), do: @clock_edges

  @doc """
  Returns the accepted reset active levels.

  ## Examples

      iex> SvPortSim.SignalSpec.reset_active_levels()
      ["high", "low"]
  """
  @spec reset_active_levels() :: [String.t()]
  def reset_active_levels(), do: @reset_active_levels

  @doc """
  Returns explicitly unsupported signal shapes for the MVP contract.

  ## Examples

      iex> :unpacked_arrays in SvPortSim.SignalSpec.unsupported_features()
      true
      iex> :non_canonical_packed_ranges in SvPortSim.SignalSpec.unsupported_features()
      true
  """
  @spec unsupported_features() :: [atom()]
  def unsupported_features() do
    [
      :escaped_identifiers,
      :implicit_widths,
      :unpacked_arrays,
      :multi_dimensional_packed_arrays,
      :structs,
      :unions,
      :enums,
      :interfaces,
      :modports,
      :classes,
      :real,
      :shortreal,
      :time,
      :strings,
      :non_bit_logic_base_types,
      :non_canonical_packed_ranges,
      :vector_clocks,
      :vector_resets
    ]
  end

  @doc """
  Builds a data-role signal specification.

  The returned map is canonical when the arguments are valid. Use `validate/1`
  when arguments may have come from an external source.

  ## Examples

      iex> spec = SvPortSim.SignalSpec.data("count", "output", "logic", 8)
      iex> [dimension] = spec["packed"]["dimensions"]
      iex> {spec["name"], spec["direction"], spec["type"], spec["width"], dimension["left"], dimension["right"]}
      {"count", "output", "logic", 8, 7, 0}
  """
  @spec data(term(), term(), term(), term(), keyword()) :: t()
  def data(name, direction, type, width, opts \\ []) when is_list(opts) do
    %{
      "name" => name,
      "direction" => direction,
      "type" => type,
      "width" => width,
      "signed" => Keyword.get(opts, :signed, false),
      "packed" => packed_metadata(width),
      "role" => %{"kind" => "data"}
    }
  end

  @doc """
  Builds a clock signal specification.

  Clocks are scalar input signals. The `:edge` option defaults to `"posedge"`.

  ## Examples

      iex> spec = SvPortSim.SignalSpec.clock("clk")
      iex> {spec["name"], spec["direction"], spec["width"], spec["role"]["kind"], spec["role"]["edge"]}
      {"clk", "input", 1, "clock", "posedge"}
  """
  @spec clock(term(), keyword()) :: t()
  def clock(name, opts \\ []) when is_list(opts) do
    %{
      "name" => name,
      "direction" => Keyword.get(opts, :direction, "input"),
      "type" => Keyword.get(opts, :type, "bit"),
      "width" => 1,
      "signed" => false,
      "packed" => @scalar_packed,
      "role" => %{"kind" => "clock", "edge" => Keyword.get(opts, :edge, "posedge")}
    }
  end

  @doc """
  Builds a reset signal specification.

  Resets are scalar input signals. The `:active` option defaults to `"high"`.

  ## Examples

      iex> spec = SvPortSim.SignalSpec.reset("rst_n", active: "low")
      iex> {spec["name"], spec["direction"], spec["width"], spec["role"]["kind"], spec["role"]["active"]}
      {"rst_n", "input", 1, "reset", "low"}
  """
  @spec reset(term(), keyword()) :: t()
  def reset(name, opts \\ []) when is_list(opts) do
    %{
      "name" => name,
      "direction" => Keyword.get(opts, :direction, "input"),
      "type" => Keyword.get(opts, :type, "bit"),
      "width" => 1,
      "signed" => false,
      "packed" => @scalar_packed,
      "role" => %{"kind" => "reset", "active" => Keyword.get(opts, :active, "high")}
    }
  end

  @doc """
  Returns example metadata for a small module.

  The example models this port list:

      module Counter(
        input  bit         clk,
        input  bit         rst_n,
        input  bit         enable,
        output logic [7:0] count,
        input  logic signed [3:0] delta
      );

  ## Examples

      iex> specs = SvPortSim.SignalSpec.example_specs()
      iex> Enum.map(specs, & &1["name"])
      ["clk", "rst_n", "enable", "count", "delta"]
      iex> SvPortSim.SignalSpec.validate_many(specs)
      :ok
  """
  @spec example_specs() :: [t()]
  def example_specs() do
    [
      clock("clk"),
      reset("rst_n", active: "low"),
      data("enable", "input", "bit", 1),
      data("count", "output", "logic", 8),
      data("delta", "input", "logic", 4, signed: true)
    ]
  end

  @doc """
  Normalises and validates one signal specification.

  Atom keys and atom enum values are accepted as input convenience and converted
  to canonical string keys and values.

  ## Examples

      iex> {:ok, spec} = SvPortSim.SignalSpec.normalize(%{
      ...>   name: "enable",
      ...>   direction: :input,
      ...>   type: :bit,
      ...>   width: 1,
      ...>   signed: false,
      ...>   packed: %{kind: :scalar, dimensions: []},
      ...>   role: %{kind: :data}
      ...> })
      iex> spec["direction"]
      "input"
  """
  @spec normalize(term()) :: {:ok, t()} | {:error, term()}
  def normalize(%{} = spec) do
    normalized = spec |> stringify_keys() |> normalize_spec_values()

    with :ok <- do_validate(normalized) do
      {:ok, normalized}
    end
  end

  def normalize(spec), do: {:error, {:invalid_signal_spec, spec}}

  @doc """
  Normalises and validates a list of signal specifications.

  ## Examples

      iex> {:ok, specs} = SvPortSim.SignalSpec.normalize_many(SvPortSim.SignalSpec.example_specs())
      iex> length(specs)
      5
  """
  @spec normalize_many(term()) :: {:ok, [t()]} | {:error, term()}
  def normalize_many(specs) when is_list(specs) do
    specs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {spec, index}, {:ok, acc} ->
      case normalize(spec) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_signal_spec, index, reason}}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  def normalize_many(specs), do: {:error, {:invalid_signal_specs, specs}}

  @doc """
  Validates one signal specification.

  ## Examples

      iex> SvPortSim.SignalSpec.validate(SvPortSim.SignalSpec.clock("clk"))
      :ok
      iex> SvPortSim.SignalSpec.validate(%{})
      {:error, {:missing_fields, "signal", ["direction", "name", "packed", "role", "signed", "type", "width"]}}
  """
  @spec validate(term()) :: :ok | {:error, term()}
  def validate(spec) do
    with {:ok, _spec} <- normalize(spec) do
      :ok
    end
  end

  @doc """
  Validates a list of signal specifications and rejects duplicate names.

  ## Examples

      iex> specs = [
      ...>   SvPortSim.SignalSpec.data("enable", "input", "bit", 1),
      ...>   SvPortSim.SignalSpec.data("enable", "output", "logic", 1)
      ...> ]
      iex> SvPortSim.SignalSpec.validate_many(specs)
      {:error, {:duplicate_signal_names, ["enable"]}}
  """
  @spec validate_many(term()) :: :ok | {:error, term()}
  def validate_many(specs) do
    with {:ok, normalized} <- normalize_many(specs) do
      validate_unique_names(normalized)
    end
  end

  @doc """
  Looks up a validated signal by name.

  ## Examples

      iex> {:ok, spec} = SvPortSim.SignalSpec.lookup(SvPortSim.SignalSpec.example_specs(), "count")
      iex> {spec["direction"], spec["width"]}
      {"output", 8}
      iex> SvPortSim.SignalSpec.lookup(SvPortSim.SignalSpec.example_specs(), "missing")
      {:error, {:unknown_signal, "missing"}}
  """
  @spec lookup(term(), term()) :: {:ok, t()} | {:error, term()}
  def lookup(specs, name) when is_binary(name) do
    with {:ok, normalized} <- normalize_many(specs),
         :ok <- validate_unique_names(normalized) do
      case Enum.find(normalized, &(&1["name"] == name)) do
        nil -> {:error, {:unknown_signal, name}}
        spec -> {:ok, spec}
      end
    end
  end

  def lookup(_specs, name), do: {:error, {:invalid_signal_name, name}}

  @doc """
  Returns whether a signal can be read by a `peek` command.

  Output and inout ports are readable.

  ## Examples

      iex> SvPortSim.SignalSpec.readable?(SvPortSim.SignalSpec.data("count", "output", "logic", 8))
      true
      iex> SvPortSim.SignalSpec.readable?(SvPortSim.SignalSpec.data("enable", "input", "bit", 1))
      false
  """
  @spec readable?(term()) :: boolean()
  def readable?(spec) do
    case normalize(spec) do
      {:ok, %{"direction" => direction}} -> direction in @readable_directions
      {:error, _reason} -> false
    end
  end

  @doc """
  Returns whether a signal can be written by a `poke` command.

  Input and inout ports are writable.

  ## Examples

      iex> SvPortSim.SignalSpec.writable?(SvPortSim.SignalSpec.data("enable", "input", "bit", 1))
      true
      iex> SvPortSim.SignalSpec.writable?(SvPortSim.SignalSpec.data("count", "output", "logic", 8))
      false
  """
  @spec writable?(term()) :: boolean()
  def writable?(spec) do
    case normalize(spec) do
      {:ok, %{"direction" => direction}} -> direction in @writable_directions
      {:error, _reason} -> false
    end
  end

  @doc """
  Returns the runtime data-type descriptor for a signal.

  The descriptor is delegated to `SvPortSim.Protocol.DataType` so signal metadata
  and runtime value encoding stay aligned.

  ## Examples

      iex> {:ok, type} = SvPortSim.SignalSpec.type_descriptor(SvPortSim.SignalSpec.data("count", "output", "logic", 8))
      iex> {type.kind, type.base, type.width, type.role}
      {:vector, :logic, 8, :data}
      iex> {:ok, type} = SvPortSim.SignalSpec.type_descriptor(SvPortSim.SignalSpec.reset("rst_n", active: "low"))
      iex> {type.role, type.active}
      {:reset, :low}
  """
  @spec type_descriptor(term()) :: {:ok, DataType.t()} | {:error, term()}
  def type_descriptor(spec) do
    with {:ok, normalized} <- normalize(spec) do
      type_descriptor_from_normalized(normalized)
    end
  end

  @doc """
  Validates that a `poke` request is legal for a signal and encoded value.

  ## Examples

      iex> enable = SvPortSim.SignalSpec.data("enable", "input", "bit", 1)
      iex> SvPortSim.SignalSpec.validate_poke(enable, %{"bits" => "1", "width" => 1})
      :ok
      iex> SvPortSim.SignalSpec.validate_poke(enable, %{"bits" => "x", "width" => 1})
      {:error, {:invalid_bits, "x", ["0", "1"]}}
  """
  @spec validate_poke(term(), term()) :: :ok | {:error, term()}
  def validate_poke(spec, encoded_value) do
    with {:ok, normalized} <- normalize(spec),
         :ok <- validate_writable(normalized),
         {:ok, type} <- type_descriptor_from_normalized(normalized),
         {:ok, _value} <- DataType.decode(type, encoded_value) do
      :ok
    end
  end

  @doc """
  Validates that a `peek` request is legal for a signal.

  ## Examples

      iex> count = SvPortSim.SignalSpec.data("count", "output", "logic", 8)
      iex> SvPortSim.SignalSpec.validate_peek(count)
      :ok
      iex> enable = SvPortSim.SignalSpec.data("enable", "input", "bit", 1)
      iex> SvPortSim.SignalSpec.validate_peek(enable)
      {:error, {:not_readable, "enable", "input"}}
  """
  @spec validate_peek(term()) :: :ok | {:error, term()}
  def validate_peek(spec) do
    with {:ok, normalized} <- normalize(spec) do
      validate_readable(normalized)
    end
  end

  defp do_validate(%{} = spec) do
    with :ok <- validate_exact_keys("signal", spec, @top_level_keys),
         :ok <- validate_name(spec["name"]),
         :ok <- validate_direction(spec["direction"]),
         :ok <- validate_type(spec["type"]),
         :ok <- validate_width(spec["width"]),
         :ok <- validate_signed(spec["signed"]),
         :ok <- validate_packed(spec["packed"], spec["width"]) do
      validate_role(spec["role"], spec)
    end
  end

  defp validate_exact_keys(label, map, expected) do
    keys = Map.keys(map)
    missing = Enum.sort(expected -- keys)
    unknown = Enum.sort(keys -- expected)

    cond do
      missing != [] -> {:error, {:missing_fields, label, missing}}
      unknown != [] -> {:error, {:unknown_fields, label, unknown}}
      true -> :ok
    end
  end

  defp validate_name(name) when is_binary(name) and byte_size(name) > 0 do
    if Regex.match?(@sv_identifier, name) do
      :ok
    else
      {:error, {:invalid_name, name}}
    end
  end

  defp validate_name(name), do: {:error, {:invalid_name, name}}

  defp validate_direction(direction) when direction in @directions, do: :ok

  defp validate_direction(direction) do
    {:error, {:invalid_direction, direction, @directions}}
  end

  defp validate_type(type) when type in @types, do: :ok

  defp validate_type(type), do: {:error, {:invalid_type, type, @types}}

  defp validate_width(width) when is_integer(width) do
    if width >= 1 and width <= max_width() do
      :ok
    else
      {:error, {:invalid_width, width, max_width()}}
    end
  end

  defp validate_width(width), do: {:error, {:invalid_width, width, max_width()}}

  defp validate_signed(signed) when is_boolean(signed), do: :ok

  defp validate_signed(signed), do: {:error, {:invalid_signed, signed}}

  defp validate_packed(%{} = packed, width) do
    case packed["kind"] do
      "scalar" -> validate_scalar_packed(packed, width)
      "packed_vector" -> validate_vector_packed(packed, width)
      kind -> {:error, {:invalid_packed_kind, kind, ["scalar", "packed_vector"]}}
    end
  end

  defp validate_packed(packed, _width), do: {:error, {:invalid_packed, packed}}

  defp validate_scalar_packed(packed, width) do
    with :ok <- validate_exact_keys("packed", packed, ~w(kind dimensions)) do
      case packed["dimensions"] do
        [] when width == 1 -> :ok
        [] -> {:error, {:invalid_scalar_width, width}}
        dimensions -> {:error, {:invalid_scalar_dimensions, dimensions}}
      end
    end
  end

  defp validate_vector_packed(packed, width) do
    with :ok <- validate_exact_keys("packed", packed, ~w(kind dimensions)) do
      case packed["dimensions"] do
        [%{} = dimension] ->
          validate_vector_dimension(dimension, width)

        dimensions when is_list(dimensions) ->
          {:error, {:unsupported_packed_dimensions, length(dimensions)}}

        dimensions ->
          {:error, {:invalid_packed_dimensions, dimensions}}
      end
    end
  end

  defp validate_vector_dimension(dimension, width) do
    with :ok <- validate_exact_keys("packed dimension", dimension, ~w(left right)),
         :ok <- validate_dimension_integer(dimension, "left"),
         :ok <- validate_dimension_integer(dimension, "right") do
      left = dimension["left"]
      right = dimension["right"]

      cond do
        width == 1 ->
          {:error, {:invalid_packed_vector_width, width}}

        left == width - 1 and right == 0 ->
          :ok

        true ->
          {:error, {:unsupported_packed_range, dimension, :canonical_range_required}}
      end
    end
  end

  defp validate_dimension_integer(dimension, key) do
    value = dimension[key]

    if is_integer(value) do
      :ok
    else
      {:error, {:invalid_packed_dimension, key, value}}
    end
  end

  defp validate_role(%{} = role, spec) do
    case role["kind"] do
      "data" -> validate_data_role(role)
      "clock" -> validate_clock_role(role, spec)
      "reset" -> validate_reset_role(role, spec)
      kind -> {:error, {:invalid_role_kind, kind, @role_kinds}}
    end
  end

  defp validate_role(role, _spec), do: {:error, {:invalid_role, role}}

  defp validate_data_role(role) do
    validate_exact_keys("role", role, ~w(kind))
  end

  defp validate_clock_role(role, spec) do
    with :ok <- validate_exact_keys("clock role", role, ~w(kind edge)),
         :ok <- validate_clock_edge(role["edge"]),
         :ok <- validate_role_input("clock", spec),
         :ok <- validate_role_scalar("clock", spec) do
      validate_role_unsigned("clock", spec)
    end
  end

  defp validate_reset_role(role, spec) do
    with :ok <- validate_exact_keys("reset role", role, ~w(kind active)),
         :ok <- validate_reset_active(role["active"]),
         :ok <- validate_role_input("reset", spec),
         :ok <- validate_role_scalar("reset", spec) do
      validate_role_unsigned("reset", spec)
    end
  end

  defp validate_clock_edge(edge) when edge in @clock_edges, do: :ok

  defp validate_clock_edge(edge), do: {:error, {:invalid_clock_edge, edge, @clock_edges}}

  defp validate_reset_active(active) when active in @reset_active_levels, do: :ok

  defp validate_reset_active(active) do
    {:error, {:invalid_reset_active_level, active, @reset_active_levels}}
  end

  defp validate_role_input(_role, %{"direction" => "input"}), do: :ok

  defp validate_role_input(role, %{"direction" => direction}) do
    {:error, {:invalid_role_direction, role, direction}}
  end

  defp validate_role_scalar(_role, %{"width" => 1}), do: :ok

  defp validate_role_scalar(role, %{"width" => width}),
    do: {:error, {:role_requires_scalar, role, width}}

  defp validate_role_unsigned(_role, %{"signed" => false}), do: :ok

  defp validate_role_unsigned(role, %{"signed" => signed}) do
    {:error, {:role_requires_unsigned, role, signed}}
  end

  defp validate_unique_names(specs) do
    duplicates =
      specs
      |> Enum.map(& &1["name"])
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(fn {name, _count} -> name end)
      |> Enum.sort()

    if duplicates == [] do
      :ok
    else
      {:error, {:duplicate_signal_names, duplicates}}
    end
  end

  defp validate_readable(%{"direction" => direction, "name" => name}) do
    if direction in @readable_directions do
      :ok
    else
      {:error, {:not_readable, name, direction}}
    end
  end

  defp validate_writable(%{"direction" => direction, "name" => name}) do
    if direction in @writable_directions do
      :ok
    else
      {:error, {:not_writable, name, direction}}
    end
  end

  defp type_descriptor_from_normalized(%{"role" => %{"kind" => "clock"}, "type" => type}) do
    DataType.clock(base_atom(type))
  end

  defp type_descriptor_from_normalized(%{
         "role" => %{"kind" => "reset", "active" => active},
         "type" => type
       }) do
    DataType.reset(base: base_atom(type), active: reset_active_atom(active))
  end

  defp type_descriptor_from_normalized(%{"type" => type, "width" => 1}) do
    DataType.scalar(base_atom(type))
  end

  defp type_descriptor_from_normalized(%{"type" => type, "width" => width, "signed" => signed}) do
    DataType.vector(base_atom(type), width, signed: signed)
  end

  defp base_atom("bit"), do: :bit
  defp base_atom("logic"), do: :logic

  defp reset_active_atom("high"), do: :high
  defp reset_active_atom("low"), do: :low

  defp packed_metadata(1), do: @scalar_packed

  defp packed_metadata(width) when is_integer(width) and width > 1 do
    %{"kind" => "packed_vector", "dimensions" => [%{"left" => width - 1, "right" => 0}]}
  end

  defp packed_metadata(_width), do: @scalar_packed

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {string_key(key), stringify_value(value)} end)
  end

  defp stringify_value(%{} = value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp string_key(key) when is_atom(key), do: Atom.to_string(key)
  defp string_key(key), do: key

  defp normalize_spec_values(spec) do
    spec
    |> update_value("direction", &atom_to_string/1)
    |> update_value("type", &atom_to_string/1)
    |> update_value("packed", &normalize_packed_values/1)
    |> update_value("role", &normalize_role_values/1)
  end

  defp normalize_packed_values(%{} = packed) do
    update_value(packed, "kind", &atom_to_string/1)
  end

  defp normalize_packed_values(packed), do: packed

  defp normalize_role_values(%{} = role) do
    role
    |> update_value("kind", &atom_to_string/1)
    |> update_value("edge", &atom_to_string/1)
    |> update_value("active", &atom_to_string/1)
  end

  defp normalize_role_values(role), do: role

  defp update_value(map, key, fun) do
    if Map.has_key?(map, key) do
      Map.update!(map, key, fun)
    else
      map
    end
  end

  defp atom_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_to_string(value), do: value
end
