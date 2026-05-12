defmodule SvPortSim.Verilator.Wrapper.AccessorTest do
  use ExUnit.Case, async: true

  alias SvPortSim.SignalSpec
  alias SvPortSim.Verilator.Wrapper.Accessor

  describe "context/1" do
    test "builds empty template fragments for an empty signal list" do
      assert {:ok, context} = Accessor.context([])

      assert %{
               normalized_signal_specs: [],
               signal_specs_json: "[]",
               poke_cases: "",
               peek_cases: ""
             } = context
    end

    test "normalizes signal specs and emits deterministic metadata JSON" do
      assert {:ok, context} = Accessor.context(accessor_fixture_specs())

      assert Enum.map(context.normalized_signal_specs, & &1["name"]) == [
               "enable",
               "count",
               "bus",
               "wide"
             ]

      assert context.signal_specs_json ==
               ~S([{"direction":"input","name":"enable","packed":{"dimensions":[],"kind":"scalar"},"role":{"kind":"data"},"signed":false,"type":"bit","width":1},{"direction":"output","name":"count","packed":{"dimensions":[{"left":7,"right":0}],"kind":"packed_vector"},"role":{"kind":"data"},"signed":false,"type":"logic","width":8},{"direction":"inout","name":"bus","packed":{"dimensions":[{"left":3,"right":0}],"kind":"packed_vector"},"role":{"kind":"data"},"signed":false,"type":"logic","width":4},{"direction":"input","name":"wide","packed":{"dimensions":[{"left":64,"right":0}],"kind":"packed_vector"},"role":{"kind":"data"},"signed":false,"type":"logic","width":65}])
    end

    test "emits poke cases in signal order" do
      assert {:ok, context} = Accessor.context(accessor_fixture_specs())

      assert normalize_cpp(context.poke_cases) ==
               normalize_cpp(~S"""
               if (signal == "enable") {
                 if (!valid_two_state_encoded_value(value, 1)) {
                   return invalid_value_accessor(signal, "invalid encoded value");
                 }
                 auto top = session.top_model();
                 top->enable = static_cast<decltype(top->enable)>(bits_to_uint64(value.bits));
                 session.eval();
                 return ok_accessor(encode_signal(static_cast<std::uint64_t>(top->enable), 1));
               }

               if (signal == "count") {
                 return invalid_signal_accessor(signal, "signal is not writable");
               }

               if (signal == "bus") {
                 if (!valid_two_state_encoded_value(value, 4)) {
                   return invalid_value_accessor(signal, "invalid encoded value");
                 }
                 auto top = session.top_model();
                 top->bus = static_cast<decltype(top->bus)>(bits_to_uint64(value.bits));
                 session.eval();
                 return ok_accessor(encode_signal(static_cast<std::uint64_t>(top->bus), 4));
               }

               if (signal == "wide") {
                 return invalid_signal_accessor(signal, "signal shape is not supported by generated accessors");
               }
               """)
    end

    test "emits peek cases in signal order" do
      assert {:ok, context} = Accessor.context(accessor_fixture_specs())

      assert normalize_cpp(context.peek_cases) ==
               normalize_cpp(~S"""
               if (signal == "enable") {
                 return invalid_signal_accessor(signal, "signal is not readable");
               }

               if (signal == "count") {
                 auto top = session.top_model();
                 return ok_accessor(encode_signal(static_cast<std::uint64_t>(top->count), 8));
               }

               if (signal == "bus") {
                 auto top = session.top_model();
                 return ok_accessor(encode_signal(static_cast<std::uint64_t>(top->bus), 4));
               }

               if (signal == "wide") {
                 return invalid_signal_accessor(signal, "signal shape is not supported by generated accessors");
               }
               """)
    end

    test "treats SystemVerilog-only identifiers as unsupported native C++ fields" do
      specs = [SignalSpec.data("debug$value", "inout", "logic", 1)]

      assert {:ok, context} = Accessor.context(specs)

      assert context.signal_specs_json =~ ~S("name":"debug$value")
      assert context.poke_cases =~ ~s|if (signal == "debug$value")|
      assert context.peek_cases =~ ~s|if (signal == "debug$value")|
      assert context.poke_cases =~ "signal shape is not supported by generated accessors"
      assert context.peek_cases =~ "signal shape is not supported by generated accessors"

      refute context.poke_cases =~ "top->debug$value"
      refute context.peek_cases =~ "top->debug$value"
    end

    test "keeps width 64 native accessors supported and width 65 unsupported" do
      specs = [
        SignalSpec.data("word64", "inout", "logic", 64),
        SignalSpec.data("word65", "inout", "logic", 65)
      ]

      assert {:ok, context} = Accessor.context(specs)

      assert context.poke_cases =~ "valid_two_state_encoded_value(value, 64)"
      assert context.poke_cases =~ "top->word64 ="
      assert context.peek_cases =~ "top->word64"

      assert context.poke_cases =~ ~s|if (signal == "word65")|
      assert context.peek_cases =~ ~s|if (signal == "word65")|
      refute context.poke_cases =~ "top->word65 ="
      refute context.peek_cases =~ "top->word65"
    end

    test "normalizes atom-keyed specs before generating accessor cases" do
      specs = [
        %{
          name: "enable",
          direction: :input,
          type: :bit,
          width: 1,
          signed: false,
          packed: %{kind: :scalar, dimensions: []},
          role: %{kind: :data}
        }
      ]

      assert {:ok, context} = Accessor.context(specs)
      assert %{normalized_signal_specs: [normalized]} = context

      assert normalized["name"] == "enable"
      assert normalized["direction"] == "input"
      assert normalized["type"] == "bit"
      assert normalized["packed"] == %{"kind" => "scalar", "dimensions" => []}
      assert normalized["role"] == %{"kind" => "data"}

      assert context.signal_specs_json ==
               ~S([{"direction":"input","name":"enable","packed":{"dimensions":[],"kind":"scalar"},"role":{"kind":"data"},"signed":false,"type":"bit","width":1}])

      assert context.poke_cases =~ ~s|if (signal == "enable")|

      assert context.poke_cases =~
               "top->enable = static_cast<decltype(top->enable)>(bits_to_uint64(value.bits));"

      assert context.peek_cases =~
               ~s|return invalid_signal_accessor(signal, "signal is not readable");|
    end

    test "wraps SignalSpec validation failures with invalid_signal_specs" do
      specs = [
        SignalSpec.data("enable", "input", "bit", 1),
        SignalSpec.data("enable", "output", "logic", 1)
      ]

      assert Accessor.context(specs) ==
               {:error, {:invalid_signal_specs, {:duplicate_signal_names, ["enable"]}}}
    end
  end

  defp accessor_fixture_specs do
    [
      SignalSpec.data("enable", "input", "bit", 1),
      SignalSpec.data("count", "output", "logic", 8),
      SignalSpec.data("bus", "inout", "logic", 4),
      SignalSpec.data("wide", "input", "logic", 65)
    ]
  end

  defp normalize_cpp(source) do
    source
    |> String.replace(~r/\s+/, " ")
    |> String.replace(~r/\s*([{}();,])\s*/, "\\1")
    |> String.replace(~r/\s*(==|=|->|::|<|>)\s*/, "\\1")
    |> String.trim()
  end
end
