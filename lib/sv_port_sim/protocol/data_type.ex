defmodule SvPortSim.Protocol.DataType do
  @max_vector_width 4096

  # credo:disable-for-next-line Credo.Check.Readability.StrictModuleLayout
  @moduledoc """
  Defines the MVP SystemVerilog data-type subset and runtime value encoding.

  This module is the single source of truth for the value shapes that the
  runtime protocol accepts in the first release. It is intentionally narrower
  than SystemVerilog: only scalar `bit` and `logic`, one-dimensional packed
  vectors, explicit signed and unsigned integer views, and clock/reset roles are
  supported.

  ## Runtime representation

  Every runtime value is encoded as a map with two fields:

    * `:bits` - a string containing one character per bit
    * `:width` - the encoded bit width

  Bit strings are ordered from the most significant bit to the least significant
  bit. For the canonical packed vector range `[width - 1:0]`, index `width - 1`
  is the first character and index `0` is the last character.

  Two-state values may only contain `"0"` and `"1"`. Four-state values may also
  contain `"x"` for unknown and `"z"` for high impedance. `"x"` and `"z"` are
  preserved for scalar and vector values, but they are never accepted for integer
  values because integers are numeric views over two-state bits.

  ## Supported MVP subset

  | MVP type | SystemVerilog shape | Runtime value |
  | --- | --- | --- |
  | `:bit` | `bit` | one two-state bit |
  | `:logic` | `logic` | one four-state bit |
  | `{:bit_vector, width}` | `bit [width - 1:0]` | two-state bit string |
  | `{:logic_vector, width}` | `logic [width - 1:0]` | four-state bit string |
  | `{:uint, width}` | unsigned numeric view | Elixir non-negative integer |
  | `{:int, width}` | signed numeric view | Elixir integer using two's complement |
  | `:clock` | scalar `bit` role | one two-state bit |
  | `:reset` | scalar `bit` role | one two-state bit with active level |

  Vector widths are constrained to `1..#{@max_vector_width}` bits. Packed vector
  ranges are canonicalised to `[width - 1:0]`; non-canonical source ranges can be
  represented only after conversion to this runtime width and ordering.

  ## Examples

      iex> SvPortSim.Protocol.DataType.max_vector_width()
      4096

      iex> SvPortSim.Protocol.DataType.supported?(:bit)
      true

      iex> SvPortSim.Protocol.DataType.supported?({:logic_vector, 8})
      true

      iex> SvPortSim.Protocol.DataType.supported?({:logic_vector, 0})
      false

      iex> SvPortSim.Protocol.DataType.encode({:logic_vector, 4}, "10XZ")
      {:ok, %{bits: "10xz", width: 4}}

      iex> SvPortSim.Protocol.DataType.encode({:bit_vector, 4}, "10xz")
      {:error, {:invalid_bits, "10xz", ["0", "1"]}}

      iex> {:ok, type} = SvPortSim.Protocol.DataType.signed_integer(8)
      iex> SvPortSim.Protocol.DataType.encode(type, -1)
      {:ok, %{bits: "11111111", width: 8}}
      iex> SvPortSim.Protocol.DataType.decode(type, %{bits: "11111110"})
      {:ok, -2}

      iex> {:ok, clock} = SvPortSim.Protocol.DataType.clock()
      iex> clock.role
      :clock
      iex> SvPortSim.Protocol.DataType.encode(clock, true)
      {:ok, %{bits: "1", width: 1}}
  """

  import Bitwise, only: [<<<: 2]

  @two_state_bits ["0", "1"]
  @four_state_bits ["0", "1", "x", "z"]
  @supported_bases [:bit, :logic]
  @supported_kinds [:scalar, :vector, :integer]
  @supported_roles [:data, :clock, :reset]
  @reset_levels [:high, :low]

  @typedoc "A supported SystemVerilog base type."
  @type base :: :bit | :logic

  @typedoc "A supported runtime type category."
  @type kind :: :scalar | :vector | :integer

  @typedoc "A supported signal role."
  @type role :: :data | :clock | :reset

  @typedoc "The accepted state space for encoded bits."
  @type states :: :two | :four

  @typedoc "A normalized MVP data-type descriptor."
  @type t :: %{
          required(:base) => base(),
          required(:kind) => kind(),
          required(:role) => role(),
          required(:signed) => boolean(),
          required(:states) => states(),
          required(:width) => pos_integer(),
          optional(:active) => :high | :low
        }

  @typedoc "A protocol value encoded as a bit string plus its width."
  @type encoded_value :: %{required(:bits) => String.t(), required(:width) => pos_integer()}

  @typedoc "Values accepted by `normalize/1` as type descriptors."
  @type typeish ::
          t()
          | :bit
          | :logic
          | :clock
          | :reset
          | {:clock, base()}
          | {:reset, :high | :low}
          | {:reset, :high | :low, base()}
          | {:bit_vector, pos_integer()}
          | {:bit_vector, pos_integer(), boolean() | :signed | :unsigned}
          | {:logic_vector, pos_integer()}
          | {:logic_vector, pos_integer(), boolean() | :signed | :unsigned}
          | {:uint, pos_integer()}
          | {:int, pos_integer()}
          | {:integer, pos_integer(), boolean() | :signed | :unsigned}

  @typedoc "A decoded native Elixir value."
  @type native_value :: integer() | :x | :z | String.t()

  @doc """
  Returns the maximum packed-vector width supported by the MVP runtime contract.

  ## Examples

      iex> SvPortSim.Protocol.DataType.max_vector_width()
      4096
  """
  @spec max_vector_width() :: pos_integer()
  def max_vector_width(), do: @max_vector_width

  @doc """
  Returns an explicit table of the data types supported by the MVP.

  The table is data, not prose, so tests and downstream modules can assert that
  the supported subset has not changed accidentally.

  ## Examples

      iex> SvPortSim.Protocol.DataType.supported_types() |> Enum.map(& &1.name)
      [:bit, :logic, :bit_vector, :logic_vector, :unsigned_integer, :signed_integer, :clock, :reset]
  """
  @spec supported_types() :: [map()]
  def supported_types() do
    [
      %{
        name: :bit,
        kind: :scalar,
        base: :bit,
        states: :two,
        width: 1,
        signed: false,
        roles: [:data],
        encoding: :bits
      },
      %{
        name: :logic,
        kind: :scalar,
        base: :logic,
        states: :four,
        width: 1,
        signed: false,
        roles: [:data],
        encoding: :bits
      },
      %{
        name: :bit_vector,
        kind: :vector,
        base: :bit,
        states: :two,
        width: {:range, 1, @max_vector_width},
        signed: :explicit,
        roles: [:data],
        encoding: :bits
      },
      %{
        name: :logic_vector,
        kind: :vector,
        base: :logic,
        states: :four,
        width: {:range, 1, @max_vector_width},
        signed: :explicit,
        roles: [:data],
        encoding: :bits
      },
      %{
        name: :unsigned_integer,
        kind: :integer,
        base: :bit,
        states: :two,
        width: {:range, 1, @max_vector_width},
        signed: false,
        roles: [:data],
        encoding: :bits
      },
      %{
        name: :signed_integer,
        kind: :integer,
        base: :bit,
        states: :two,
        width: {:range, 1, @max_vector_width},
        signed: true,
        roles: [:data],
        encoding: :bits
      },
      %{
        name: :clock,
        kind: :scalar,
        base: :bit,
        states: :two,
        width: 1,
        signed: false,
        roles: [:clock],
        encoding: :bits
      },
      %{
        name: :reset,
        kind: :scalar,
        base: :bit,
        states: :two,
        width: 1,
        signed: false,
        roles: [:reset],
        active: @reset_levels,
        encoding: :bits
      }
    ]
  end

  @doc """
  Returns the explicitly unsupported SystemVerilog type forms for the MVP.

  This list is intentionally conservative. A type form should be removed from
  this list only when `normalize/1`, `encode/2`, and `decode/2` define exact
  behaviour for it.

  ## Examples

      iex> :unpacked_arrays in SvPortSim.Protocol.DataType.unsupported_features()
      true
  """
  @spec unsupported_features() :: [atom()]
  def unsupported_features() do
    [
      :unpacked_arrays,
      :multi_dimensional_packed_arrays,
      :structs,
      :unions,
      :enums,
      :classes,
      :interfaces,
      :modports,
      :queues,
      :dynamic_arrays,
      :associative_arrays,
      :strings,
      :events,
      :chandle,
      :real,
      :shortreal,
      :realtime,
      :time,
      :net_strengths,
      :drive_strengths,
      :four_state_integer_values,
      :non_canonical_packed_ranges,
      :user_defined_types
    ]
  end

  @doc """
  Returns a normalized descriptor for scalar `bit`.

  ## Examples

      iex> SvPortSim.Protocol.DataType.bit().states
      :two
  """
  @spec bit() :: t()
  def bit(), do: type(:scalar, :bit, 1, false, :data)

  @doc """
  Returns a normalized descriptor for scalar `logic`.

  ## Examples

      iex> SvPortSim.Protocol.DataType.logic().states
      :four
  """
  @spec logic() :: t()
  def logic(), do: type(:scalar, :logic, 1, false, :data)

  @doc """
  Returns a normalized scalar descriptor for `base`.

  ## Examples

      iex> {:ok, type} = SvPortSim.Protocol.DataType.scalar(:bit)
      iex> {type.base, type.width, type.states}
      {:bit, 1, :two}

      iex> SvPortSim.Protocol.DataType.scalar(:byte)
      {:error, {:invalid_base, :byte}}
  """
  @spec scalar(term()) :: {:ok, t()} | {:error, term()}
  def scalar(:bit), do: {:ok, bit()}
  def scalar(:logic), do: {:ok, logic()}
  def scalar(base), do: {:error, {:invalid_base, base}}

  @doc """
  Returns a normalized descriptor for a packed `bit` vector.

  ## Examples

      iex> {:ok, type} = SvPortSim.Protocol.DataType.bit_vector(4)
      iex> type.width
      4
  """
  @spec bit_vector(term(), keyword()) :: {:ok, t()} | {:error, term()}
  def bit_vector(width, opts \\ []), do: vector(:bit, width, opts)

  @doc """
  Returns a normalized descriptor for a packed `logic` vector.

  ## Examples

      iex> {:ok, type} = SvPortSim.Protocol.DataType.logic_vector(4, signed: :signed)
      iex> {type.states, type.signed}
      {:four, true}
  """
  @spec logic_vector(term(), keyword()) :: {:ok, t()} | {:error, term()}
  def logic_vector(width, opts \\ []), do: vector(:logic, width, opts)

  @doc """
  Returns a normalized packed-vector descriptor.

  `:signed` may be `true`, `false`, `:signed`, or `:unsigned`.

  ## Examples

      iex> {:ok, type} = SvPortSim.Protocol.DataType.vector(:logic, 2, signed: true)
      iex> {type.base, type.width, type.signed, type.states}
      {:logic, 2, true, :four}
  """
  @spec vector(term(), term(), keyword()) :: {:ok, t()} | {:error, term()}
  def vector(base, width, opts \\ []) when is_list(opts) do
    with {:ok, base} <- base(base),
         {:ok, width} <- width(width),
         {:ok, signed} <- signedness(Keyword.get(opts, :signed, false)) do
      {:ok, type(:vector, base, width, signed, :data)}
    end
  end

  @doc """
  Returns a normalized descriptor for an unsigned integer view.

  ## Examples

      iex> {:ok, type} = SvPortSim.Protocol.DataType.unsigned_integer(4)
      iex> SvPortSim.Protocol.DataType.encode(type, 15)
      {:ok, %{bits: "1111", width: 4}}
  """
  @spec unsigned_integer(term()) :: {:ok, t()} | {:error, term()}
  def unsigned_integer(width), do: integer(width, signed: false)

  @doc """
  Returns a normalized descriptor for a signed integer view.

  Signed integers use two's complement bit encoding.

  ## Examples

      iex> {:ok, type} = SvPortSim.Protocol.DataType.signed_integer(4)
      iex> SvPortSim.Protocol.DataType.encode(type, -8)
      {:ok, %{bits: "1000", width: 4}}
  """
  @spec signed_integer(term()) :: {:ok, t()} | {:error, term()}
  def signed_integer(width), do: integer(width, signed: true)

  @doc """
  Returns a normalized descriptor for an integer view.

  Integer views are always two-state. Unknown and high-impedance values are not
  valid integer values in the MVP protocol.

  ## Examples

      iex> {:ok, type} = SvPortSim.Protocol.DataType.integer(4, signed: :unsigned)
      iex> {type.kind, type.width, type.signed, type.states}
      {:integer, 4, false, :two}
  """
  @spec integer(term(), keyword()) :: {:ok, t()} | {:error, term()}
  def integer(width, opts \\ []) when is_list(opts) do
    with {:ok, width} <- width(width),
         {:ok, signed} <- signedness(Keyword.get(opts, :signed, false)) do
      {:ok, type(:integer, :bit, width, signed, :data)}
    end
  end

  @doc """
  Returns a normalized descriptor for a clock signal role.

  A clock is a scalar bit or logic value with the `:clock` role. Runtime clock
  values are always driven as `0` or `1`; `x` and `z` are rejected even when the
  base type is `logic`.

  ## Examples

      iex> {:ok, clock} = SvPortSim.Protocol.DataType.clock(:logic)
      iex> {clock.role, clock.states}
      {:clock, :four}
  """
  @spec clock(term()) :: {:ok, t()} | {:error, term()}
  def clock(base \\ :bit) do
    with {:ok, type} <- scalar(base) do
      {:ok, %{type | role: :clock}}
    end
  end

  @doc """
  Returns a normalized descriptor for a reset signal role.

  Options:

    * `:base` - `:bit` or `:logic`. Defaults to `:bit`.
    * `:active` - `:high` or `:low`. Defaults to `:high`.

  Runtime reset values are always driven as `0` or `1`; `x` and `z` are rejected
  even when the base type is `logic`.

  ## Examples

      iex> {:ok, reset} = SvPortSim.Protocol.DataType.reset(active: :low)
      iex> {reset.role, reset.active}
      {:reset, :low}
  """
  @spec reset(keyword()) :: {:ok, t()} | {:error, term()}
  def reset(opts \\ []) when is_list(opts) do
    with {:ok, type} <- scalar(Keyword.get(opts, :base, :bit)),
         {:ok, active} <- reset_level(Keyword.get(opts, :active, :high)) do
      {:ok, type |> Map.put(:role, :reset) |> Map.put(:active, active)}
    end
  end

  @doc """
  Normalises a type descriptor or shorthand into the canonical map form.

  ## Examples

      iex> {:ok, type} = SvPortSim.Protocol.DataType.normalize(:bit)
      iex> {type.base, type.width, type.states}
      {:bit, 1, :two}

      iex> {:ok, type} = SvPortSim.Protocol.DataType.normalize({:logic_vector, 8, :signed})
      iex> {type.base, type.width, type.signed}
      {:logic, 8, true}
  """
  @spec normalize(typeish() | term()) :: {:ok, t()} | {:error, term()}
  def normalize(:bit), do: {:ok, bit()}
  def normalize(:logic), do: {:ok, logic()}
  def normalize(:clock), do: clock()
  def normalize(:reset), do: reset()
  def normalize({:clock, base}), do: clock(base)
  def normalize({:reset, active}), do: reset(active: active)
  def normalize({:reset, active, base}), do: reset(active: active, base: base)
  def normalize({:bit_vector, width}), do: bit_vector(width)
  def normalize({:bit_vector, width, signed}), do: bit_vector(width, signed: signed)
  def normalize({:logic_vector, width}), do: logic_vector(width)
  def normalize({:logic_vector, width, signed}), do: logic_vector(width, signed: signed)
  def normalize({:uint, width}), do: unsigned_integer(width)
  def normalize({:int, width}), do: signed_integer(width)
  def normalize({:integer, width, signed}), do: integer(width, signed: signed)

  def normalize(%{} = descriptor) do
    with {:ok, kind} <- kind(Map.get(descriptor, :kind)),
         {:ok, base} <- base(Map.get(descriptor, :base)),
         {:ok, width} <- width(Map.get(descriptor, :width)),
         {:ok, signed} <- signedness(Map.get(descriptor, :signed, false)),
         {:ok, role} <- role(Map.get(descriptor, :role, :data)),
         :ok <- validate_kind_width(kind, width),
         :ok <- validate_kind_base(kind, base),
         :ok <- validate_role(kind, width, role),
         :ok <- validate_states(descriptor, base),
         {:ok, active} <- active_level(descriptor, role) do
      descriptor = type(kind, base, width, signed, role)

      {:ok, put_active(descriptor, active)}
    end
  end

  def normalize(other), do: {:error, {:unsupported_type, other}}

  @doc """
  Returns whether a type descriptor is supported by the MVP runtime contract.

  ## Examples

      iex> SvPortSim.Protocol.DataType.supported?({:uint, 32})
      true

      iex> SvPortSim.Protocol.DataType.supported?({:real, 64})
      false
  """
  @spec supported?(term()) :: boolean()
  def supported?(type), do: match?({:ok, _type}, normalize(type))

  @doc """
  Encodes a native Elixir value as a runtime bit-string value.

  Scalar and vector values accept bit strings, bit lists, integers `0` and `1`,
  booleans, `:x`, and `:z` as appropriate for the type state space. Integer
  views accept Elixir integers and encode them as unsigned or two's complement
  bits.

  ## Examples

      iex> SvPortSim.Protocol.DataType.encode(:bit, 1)
      {:ok, %{bits: "1", width: 1}}

      iex> SvPortSim.Protocol.DataType.encode({:logic_vector, 4}, [1, 0, :x, :z])
      {:ok, %{bits: "10xz", width: 4}}

      iex> SvPortSim.Protocol.DataType.encode({:uint, 4}, 16)
      {:error, {:integer_out_of_range, 16, {0, 15}}}
  """
  @spec encode(typeish() | term(), term()) :: {:ok, encoded_value()} | {:error, term()}
  def encode(type, value) do
    with {:ok, type} <- normalize(type),
         {:ok, bits} <- encode_bits(type, value) do
      {:ok, %{bits: bits, width: type.width}}
    end
  end

  @doc """
  Encodes a value and raises `ArgumentError` on failure.

  ## Examples

      iex> SvPortSim.Protocol.DataType.encode!(:bit, false)
      %{bits: "0", width: 1}
  """
  @spec encode!(typeish() | term(), term()) :: encoded_value()
  def encode!(type, value) do
    case encode(type, value) do
      {:ok, encoded} -> encoded
      {:error, reason} -> raise ArgumentError, message: inspect(reason)
    end
  end

  @doc """
  Decodes a runtime bit-string value into a native Elixir value.

  Scalar values decode to `0`, `1`, `:x`, or `:z`. Vector values decode to a
  normalized bit string. Integer values decode to Elixir integers.

  ## Examples

      iex> SvPortSim.Protocol.DataType.decode(:logic, %{bits: "Z"})
      {:ok, :z}

      iex> SvPortSim.Protocol.DataType.decode({:logic_vector, 4}, %{bits: "10XZ"})
      {:ok, "10xz"}

      iex> SvPortSim.Protocol.DataType.decode({:int, 4}, %{bits: "1111"})
      {:ok, -1}
  """
  @spec decode(typeish() | term(), encoded_value() | map() | String.t()) ::
          {:ok, native_value()} | {:error, term()}
  def decode(type, encoded) do
    with {:ok, type} <- normalize(type),
         :ok <- validate_encoded_width(encoded, type.width),
         {:ok, bits} <- encoded_bits(encoded),
         {:ok, bits} <- normalize_bit_string(bits),
         :ok <- validate_bits_for_type(type, bits) do
      {:ok, decode_bits(type, bits)}
    end
  end

  @doc """
  Decodes an encoded runtime value and raises `ArgumentError` on failure.

  ## Examples

      iex> SvPortSim.Protocol.DataType.decode!({:uint, 4}, %{bits: "1010"})
      10
  """
  @spec decode!(typeish() | term(), encoded_value() | map() | String.t()) :: native_value()
  def decode!(type, encoded) do
    case decode(type, encoded) do
      {:ok, value} -> value
      {:error, reason} -> raise ArgumentError, message: inspect(reason)
    end
  end

  defp encode_bits(%{kind: :integer} = type, value) when is_integer(value) do
    with :ok <- validate_integer_range(type, value) do
      {:ok, integer_to_bits(type, value)}
    end
  end

  defp encode_bits(%{kind: :integer} = type, value) do
    {:error, {:invalid_value, compact_type(type), value}}
  end

  defp encode_bits(%{kind: :scalar} = type, value) do
    with {:ok, bits} <- bit_value(value),
         :ok <- validate_bits_for_type(type, bits) do
      {:ok, bits}
    end
  end

  defp encode_bits(%{kind: :vector} = type, value) do
    with {:ok, bits} <- value_bits(value),
         :ok <- validate_bits_for_type(type, bits) do
      {:ok, bits}
    end
  end

  defp value_bits(value) when is_binary(value) do
    normalize_bit_string(value)
  end

  defp value_bits(value) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, bits} ->
      case bit_value(item) do
        {:ok, bit} -> {:cont, {:ok, [bit | bits]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, bits} -> {:ok, bits |> Enum.reverse() |> Enum.join()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp value_bits(value), do: {:error, {:invalid_bits_value, value}}

  defp bit_value(0), do: {:ok, "0"}
  defp bit_value(1), do: {:ok, "1"}
  defp bit_value(false), do: {:ok, "0"}
  defp bit_value(true), do: {:ok, "1"}
  defp bit_value(:x), do: {:ok, "x"}
  defp bit_value(:z), do: {:ok, "z"}
  defp bit_value(:unknown), do: {:ok, "x"}
  defp bit_value(:high_impedance), do: {:ok, "z"}
  defp bit_value("0"), do: {:ok, "0"}
  defp bit_value("1"), do: {:ok, "1"}
  defp bit_value("x"), do: {:ok, "x"}
  defp bit_value("X"), do: {:ok, "x"}
  defp bit_value("z"), do: {:ok, "z"}
  defp bit_value("Z"), do: {:ok, "z"}
  defp bit_value(value), do: {:error, {:invalid_bit_value, value}}

  defp validate_encoded_width(%{width: width}, expected) when width == expected, do: :ok

  defp validate_encoded_width(%{width: width}, expected) when is_integer(width) do
    {:error, {:invalid_encoded_width, width, expected}}
  end

  defp validate_encoded_width(%{"width" => width}, expected) when width == expected, do: :ok

  defp validate_encoded_width(%{"width" => width}, expected) when is_integer(width) do
    {:error, {:invalid_encoded_width, width, expected}}
  end

  defp validate_encoded_width(_encoded, _expected), do: :ok

  defp encoded_bits(%{bits: bits}) when is_binary(bits), do: {:ok, bits}
  defp encoded_bits(%{"bits" => bits}) when is_binary(bits), do: {:ok, bits}
  defp encoded_bits(bits) when is_binary(bits), do: {:ok, bits}
  defp encoded_bits(encoded), do: {:error, {:invalid_encoded_value, encoded}}

  defp normalize_bit_string(bits) do
    normalized = String.downcase(bits)

    if bit_string?(normalized) do
      {:ok, normalized}
    else
      {:error, {:invalid_bits, bits, @four_state_bits}}
    end
  end

  defp bit_string?(""), do: false

  defp bit_string?(bits) do
    bits
    |> String.graphemes()
    |> Enum.all?(&(&1 in @four_state_bits))
  end

  defp validate_bits_for_type(type, bits) do
    cond do
      String.length(bits) != type.width ->
        {:error, {:invalid_bit_width, bits, type.width}}

      not Enum.all?(String.graphemes(bits), &(&1 in allowed_bits(type))) ->
        {:error, {:invalid_bits, bits, allowed_bits(type)}}

      true ->
        :ok
    end
  end

  defp allowed_bits(%{role: role}) when role in [:clock, :reset], do: @two_state_bits
  defp allowed_bits(%{states: :two}), do: @two_state_bits
  defp allowed_bits(%{states: :four}), do: @four_state_bits

  defp validate_integer_range(type, value) do
    range = integer_range(type)

    if value in range do
      :ok
    else
      {:error, {:integer_out_of_range, value, range_bounds(range)}}
    end
  end

  defp integer_range(%{signed: false, width: width}), do: 0..((1 <<< width) - 1)

  defp integer_range(%{signed: true, width: width}) do
    min = -(1 <<< (width - 1))
    max = (1 <<< (width - 1)) - 1

    min..max
  end

  defp range_bounds(%Range{first: first, last: last}), do: {first, last}

  defp integer_to_bits(%{signed: signed, width: width}, value) do
    encoded_value = if signed and value < 0, do: value + (1 <<< width), else: value

    encoded_value
    |> Integer.to_string(2)
    |> String.pad_leading(width, "0")
  end

  defp decode_bits(%{kind: :integer, signed: signed, width: width}, bits) do
    value = String.to_integer(bits, 2)

    if signed and String.first(bits) == "1" do
      value - (1 <<< width)
    else
      value
    end
  end

  defp decode_bits(%{kind: :scalar}, "0"), do: 0
  defp decode_bits(%{kind: :scalar}, "1"), do: 1
  defp decode_bits(%{kind: :scalar}, "x"), do: :x
  defp decode_bits(%{kind: :scalar}, "z"), do: :z
  defp decode_bits(%{kind: :vector}, bits), do: bits

  defp type(kind, base, width, signed, role) do
    %{base: base, kind: kind, role: role, signed: signed, states: states(base), width: width}
  end

  defp states(:bit), do: :two
  defp states(:logic), do: :four

  defp base(base) when base in @supported_bases, do: {:ok, base}
  defp base(base), do: {:error, {:invalid_base, base}}

  defp kind(kind) when kind in @supported_kinds, do: {:ok, kind}
  defp kind(kind), do: {:error, {:invalid_kind, kind}}

  defp role(role) when role in @supported_roles, do: {:ok, role}
  defp role(role), do: {:error, {:invalid_role, role}}

  defp width(width) when is_integer(width) and width >= 1 and width <= @max_vector_width do
    {:ok, width}
  end

  defp width(width) when is_integer(width) do
    {:error, {:width_out_of_range, width, @max_vector_width}}
  end

  defp width(width), do: {:error, {:invalid_width, width}}

  defp signedness(false), do: {:ok, false}
  defp signedness(:unsigned), do: {:ok, false}
  defp signedness("unsigned"), do: {:ok, false}
  defp signedness(true), do: {:ok, true}
  defp signedness(:signed), do: {:ok, true}
  defp signedness("signed"), do: {:ok, true}
  defp signedness(signed), do: {:error, {:invalid_signedness, signed}}

  defp reset_level(level) when level in @reset_levels, do: {:ok, level}
  defp reset_level(level), do: {:error, {:invalid_reset_level, level}}

  defp validate_kind_width(:scalar, 1), do: :ok
  defp validate_kind_width(:scalar, width), do: {:error, {:invalid_scalar_width, width}}
  defp validate_kind_width(_kind, _width), do: :ok

  defp validate_kind_base(:integer, :bit), do: :ok
  defp validate_kind_base(:integer, base), do: {:error, {:unsupported_integer_base, base}}
  defp validate_kind_base(_kind, _base), do: :ok

  defp validate_role(:scalar, 1, role) when role in @supported_roles, do: :ok
  defp validate_role(_kind, _width, :data), do: :ok
  defp validate_role(kind, width, role), do: {:error, {:unsupported_role, role, kind, width}}

  defp validate_states(descriptor, base) do
    expected = states(base)

    case Map.fetch(descriptor, :states) do
      {:ok, ^expected} -> :ok
      {:ok, states} -> {:error, {:invalid_states, states, expected}}
      :error -> :ok
    end
  end

  defp active_level(descriptor, :reset) do
    descriptor
    |> Map.get(:active, :high)
    |> reset_level()
  end

  defp active_level(descriptor, _role) do
    case Map.fetch(descriptor, :active) do
      {:ok, active} -> {:error, {:unexpected_active_level, active}}
      :error -> {:ok, nil}
    end
  end

  defp put_active(descriptor, nil), do: descriptor
  defp put_active(descriptor, active), do: Map.put(descriptor, :active, active)

  defp compact_type(type) do
    type
    |> Map.take([:kind, :base, :width, :signed, :role])
    |> put_active(Map.get(type, :active))
  end
end
