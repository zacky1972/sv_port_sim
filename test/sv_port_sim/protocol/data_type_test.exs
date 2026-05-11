defmodule SvPortSim.Protocol.DataTypeTest do
  use ExUnit.Case, async: true

  alias SvPortSim.Protocol.DataType

  doctest SvPortSim.Protocol.DataType

  test "supported_types/0 exposes the exact MVP subset" do
    assert Enum.map(DataType.supported_types(), & &1.name) == [
             :bit,
             :logic,
             :bit_vector,
             :logic_vector,
             :unsigned_integer,
             :signed_integer,
             :clock,
             :reset
           ]
  end

  test "unsupported_features/0 lists intentionally unsupported type forms" do
    assert :unpacked_arrays in DataType.unsupported_features()
    assert :four_state_integer_values in DataType.unsupported_features()
    refute :bit in DataType.unsupported_features()
  end

  test "normalizes shorthand scalar and vector types" do
    assert {:ok, %{kind: :scalar, base: :bit, width: 1, states: :two}} =
             DataType.normalize(:bit)

    assert {:ok, %{kind: :vector, base: :logic, width: 8, signed: true, states: :four}} =
             DataType.normalize({:logic_vector, 8, :signed})
  end

  test "rejects invalid widths and unsupported type shorthands" do
    assert {:error, {:width_out_of_range, 0, 4096}} = DataType.normalize({:bit_vector, 0})
    assert {:error, {:unsupported_type, {:real, 64}}} = DataType.normalize({:real, 64})
  end

  test "encodes and decodes four-state vectors" do
    assert {:ok, %{bits: "10xz", width: 4}} = DataType.encode({:logic_vector, 4}, [1, 0, :x, :z])
    assert {:ok, "10xz"} = DataType.decode({:logic_vector, 4}, %{bits: "10XZ"})
  end

  test "rejects x and z for two-state vectors" do
    assert {:error, {:invalid_bits, "10xz", ["0", "1"]}} =
             DataType.encode({:bit_vector, 4}, "10xz")
  end

  test "encodes and decodes unsigned integers" do
    assert {:ok, type} = DataType.unsigned_integer(4)
    assert {:ok, %{bits: "1010", width: 4}} = DataType.encode(type, 10)
    assert {:ok, 10} = DataType.decode(type, %{bits: "1010"})
    assert {:error, {:integer_out_of_range, 16, {0, 15}}} = DataType.encode(type, 16)
  end

  test "encodes and decodes signed integers using two's complement" do
    assert {:ok, type} = DataType.signed_integer(4)
    assert {:ok, %{bits: "1000", width: 4}} = DataType.encode(type, -8)
    assert {:ok, -1} = DataType.decode(type, %{bits: "1111"})
    assert {:error, {:integer_out_of_range, -9, {-8, 7}}} = DataType.encode(type, -9)
  end

  test "represents clocks and resets as scalar roles" do
    assert {:ok, clock} = DataType.clock(:logic)
    assert clock.role == :clock
    assert {:ok, %{bits: "1", width: 1}} = DataType.encode(clock, true)
    assert {:error, {:invalid_bits, "x", ["0", "1"]}} = DataType.encode(clock, :x)

    assert {:ok, reset} = DataType.reset(base: :logic, active: :low)
    assert reset.role == :reset
    assert reset.active == :low
  end

  test "bang helpers raise ArgumentError with the validation reason" do
    assert %{bits: "0", width: 1} = DataType.encode!(:bit, false)

    assert_raise ArgumentError, ~s({:invalid_bits, "x", ["0", "1"]}), fn ->
      DataType.encode!(:bit, :x)
    end
  end
end
