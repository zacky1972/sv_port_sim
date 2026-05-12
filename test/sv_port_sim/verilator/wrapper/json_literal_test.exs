defmodule SvPortSim.Verilator.Wrapper.JsonLiteralTest do
  use ExUnit.Case, async: true

  alias SvPortSim.SignalSpec
  alias SvPortSim.Verilator.Wrapper.Accessor
  alias SvPortSim.Verilator.Wrapper.JsonLiteral

  describe "json/1" do
    test "encodes JSON scalar literals" do
      assert JsonLiteral.json(nil) == "null"
      assert JsonLiteral.json(true) == "true"
      assert JsonLiteral.json(false) == "false"
      assert JsonLiteral.json(0) == "0"
      assert JsonLiteral.json(-42) == "-42"
    end

    test "encodes JSON string literals with deterministic escaping" do
      value = "quote\" backslash\\ backspace\b formfeed\f newline\n carriage\r tab\t"

      assert JsonLiteral.json(value) ==
               ~S("quote\" backslash\\ backspace\b formfeed\f newline\n carriage\r tab\t")
    end

    test "preserves list order and encodes nested values" do
      value = ["first", 2, false, nil, %{"b" => 2, "a" => 1}]

      assert JsonLiteral.json(value) == ~S(["first",2,false,null,{"a":1,"b":2}])
    end

    test "encodes maps with key order sorted by stringified key" do
      value = %{
        "z" => 3,
        "a" => 1,
        :nested => %{"b" => false, "a" => nil},
        "list" => [%{"right" => 0, "left" => 7}]
      }

      assert JsonLiteral.json(value) ==
               ~S({"a":1,"list":[{"left":7,"right":0}],"nested":{"a":null,"b":false},"z":3})
    end

    test "matches the metadata JSON currently emitted by Accessor.context/1" do
      specs = [
        SignalSpec.data("enable", "input", "bit", 1),
        SignalSpec.data("count", "output", "logic", 8),
        SignalSpec.data("bus", "inout", "logic", 4)
      ]

      assert {:ok, context} = Accessor.context(specs)

      assert JsonLiteral.json(context.normalized_signal_specs) == context.signal_specs_json
    end
  end

  describe "cpp_string/1" do
    test "escapes content for insertion inside a C++ string literal" do
      value = "quote\" backslash\\ newline\n carriage\r tab\t"

      assert JsonLiteral.cpp_string(value) ==
               ~S(quote\" backslash\\ newline\n carriage\r tab\t)
    end

    test "does not add surrounding quotes" do
      assert JsonLiteral.cpp_string("Counter") == "Counter"
      assert JsonLiteral.cpp_string("debug$value") == "debug$value"
    end
  end
end
