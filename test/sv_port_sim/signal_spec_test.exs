defmodule SvPortSim.SignalSpecTest do
  use ExUnit.Case, async: true

  doctest SvPortSim.SignalSpec

  alias SvPortSim.SignalSpec

  test "example specs satisfy schema and expose explicit clock and reset roles" do
    specs = SignalSpec.example_specs()

    assert :ok = SignalSpec.validate_many(specs)

    assert {:ok, clk} = SignalSpec.lookup(specs, "clk")
    assert clk["role"] == %{"kind" => "clock", "edge" => "posedge"}

    assert {:ok, rst} = SignalSpec.lookup(specs, "rst_n")
    assert rst["role"] == %{"kind" => "reset", "active" => "low"}
  end

  test "input output and inout directions determine poke and peek access" do
    input = SignalSpec.data("enable", "input", "bit", 1)
    output = SignalSpec.data("count", "output", "logic", 4)
    bus = SignalSpec.data("bus", "inout", "logic", 4)

    assert :ok = SignalSpec.validate_poke(input, %{"bits" => "1", "width" => 1})
    assert {:error, {:not_readable, "enable", "input"}} = SignalSpec.validate_peek(input)

    assert :ok = SignalSpec.validate_peek(output)

    assert {:error, {:not_writable, "count", "output"}} =
             SignalSpec.validate_poke(output, %{"bits" => "0000", "width" => 4})

    assert :ok = SignalSpec.validate_poke(bus, %{"bits" => "10xz", "width" => 4})
    assert :ok = SignalSpec.validate_peek(bus)
  end

  test "encoded poke values must match the signal type and width" do
    bit = SignalSpec.data("enable", "input", "bit", 1)
    vector = SignalSpec.data("count", "input", "logic", 4)

    assert {:error, {:invalid_bits, "x", ["0", "1"]}} =
             SignalSpec.validate_poke(bit, %{"bits" => "x", "width" => 1})

    assert {:error, {:invalid_encoded_width, 3, 4}} =
             SignalSpec.validate_poke(vector, %{"bits" => "101", "width" => 3})
  end

  test "unsupported packed ranges are rejected explicitly" do
    spec = SignalSpec.data("count", "output", "logic", 8)
    spec = put_in(spec, ["packed", "dimensions"], [%{"left" => 0, "right" => 7}])

    assert {:error,
            {:unsupported_packed_range, %{"left" => 0, "right" => 7}, :canonical_range_required}} =
             SignalSpec.validate(spec)
  end

  test "clock and reset roles require scalar input metadata" do
    bad_clock = SignalSpec.clock("clk", edge: "rising")

    assert {:error, {:invalid_clock_edge, "rising", ["posedge", "negedge"]}} =
             SignalSpec.validate(bad_clock)

    reset = SignalSpec.reset("rst_n")

    reset = %{
      reset
      | "width" => 2,
        "packed" => %{
          "kind" => "packed_vector",
          "dimensions" => [%{"left" => 1, "right" => 0}]
        }
    }

    assert {:error, {:role_requires_scalar, "reset", 2}} = SignalSpec.validate(reset)
  end

  test "minimum generated Verilator workflow ports use the stable SignalSpec contract" do
    specs = [
      SignalSpec.clock("clk", type: "logic"),
      SignalSpec.reset("rst", type: "logic", active: "high"),
      SignalSpec.data("s_valid", "input", "logic", 1),
      SignalSpec.data("a", "input", "logic", 8),
      SignalSpec.data("b", "input", "logic", 8),
      SignalSpec.data("m_valid", "output", "logic", 1),
      SignalSpec.data("y", "output", "logic", 8)
    ]

    assert :ok = SignalSpec.validate_many(specs)

    assert {:ok, clk} = SignalSpec.lookup(specs, "clk")
    assert clk["direction"] == "input"
    assert clk["type"] == "logic"
    assert clk["width"] == 1
    assert clk["packed"] == %{"kind" => "scalar", "dimensions" => []}
    assert clk["role"] == %{"kind" => "clock", "edge" => "posedge"}

    assert {:ok, rst} = SignalSpec.lookup(specs, "rst")
    assert rst["direction"] == "input"
    assert rst["type"] == "logic"
    assert rst["width"] == 1
    assert rst["packed"] == %{"kind" => "scalar", "dimensions" => []}
    assert rst["role"] == %{"kind" => "reset", "active" => "high"}

    assert {:ok, s_valid} = SignalSpec.lookup(specs, "s_valid")
    assert :ok = SignalSpec.validate_poke(s_valid, %{"bits" => "1", "width" => 1})
    assert {:error, {:not_readable, "s_valid", "input"}} = SignalSpec.validate_peek(s_valid)

    for input_name <- ~w(a b) do
      assert {:ok, input} = SignalSpec.lookup(specs, input_name)
      assert input["direction"] == "input"
      assert input["type"] == "logic"
      assert input["width"] == 8

      assert input["packed"] == %{
               "kind" => "packed_vector",
               "dimensions" => [%{"left" => 7, "right" => 0}]
             }

      assert :ok = SignalSpec.validate_poke(input, %{"bits" => "00001111", "width" => 8})
      assert {:error, {:not_readable, ^input_name, "input"}} = SignalSpec.validate_peek(input)
    end

    assert {:ok, m_valid} = SignalSpec.lookup(specs, "m_valid")
    assert :ok = SignalSpec.validate_peek(m_valid)

    assert {:error, {:not_writable, "m_valid", "output"}} =
             SignalSpec.validate_poke(m_valid, %{"bits" => "0", "width" => 1})

    assert {:ok, y} = SignalSpec.lookup(specs, "y")
    assert y["direction"] == "output"
    assert y["type"] == "logic"
    assert y["width"] == 8

    assert y["packed"] == %{
             "kind" => "packed_vector",
             "dimensions" => [%{"left" => 7, "right" => 0}]
           }

    assert :ok = SignalSpec.validate_peek(y)

    assert {:error, {:not_writable, "y", "output"}} =
             SignalSpec.validate_poke(y, %{"bits" => "11111111", "width" => 8})
  end

  test "unknown top-level fields and duplicate names are invalid" do
    spec = SignalSpec.data("count", "output", "logic", 8)

    assert {:error, {:unknown_fields, "signal", ["dpi_name"]}} =
             SignalSpec.validate(Map.put(spec, "dpi_name", "count"))

    specs = [
      SignalSpec.data("enable", "input", "bit", 1),
      SignalSpec.data("enable", "output", "logic", 1)
    ]

    assert {:error, {:duplicate_signal_names, ["enable"]}} = SignalSpec.validate_many(specs)
  end

  test "atom keys and enum values are normalized to canonical strings" do
    assert {:ok, spec} =
             SignalSpec.normalize(%{
               name: "enable",
               direction: :input,
               type: :bit,
               width: 1,
               signed: false,
               packed: %{kind: :scalar, dimensions: []},
               role: %{kind: :data}
             })

    assert spec["direction"] == "input"
    assert spec["type"] == "bit"
    assert spec["role"] == %{"kind" => "data"}
  end
end
