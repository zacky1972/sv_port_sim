defmodule SvPortSim.Verilator.Wrapper.Accessor do
  @moduledoc """
  Builds deterministic C++ accessor fragments for generated Verilator wrappers.

  This module owns the conversion from `SvPortSim.SignalSpec` metadata to:

    * normalized signal metadata
    * JSON metadata embedded in the wrapper source
    * `poke_signal/3` dispatch cases
    * `peek_signal/2` dispatch cases

  The generated fragments intentionally support only direct native C++ field
  access for top-level Verilated fields whose names are valid C++ identifiers
  and whose widths fit in a `std::uint64_t` value.
  """

  alias SvPortSim.SignalSpec
  alias SvPortSim.Verilator.Wrapper.JsonLiteral

  @cpp_identifier ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/
  @max_native_accessor_width 64

  @type context :: %{
          normalized_signal_specs: [SignalSpec.t()],
          signal_specs_json: String.t(),
          poke_cases: String.t(),
          peek_cases: String.t()
        }

  @doc """
  Builds wrapper accessor generation context from signal specifications.

  `signal_specs` are normalized and validated through `SvPortSim.SignalSpec`.
  Validation failures are wrapped with `{:invalid_signal_specs, reason}` so the
  caller can surface the same error shape as `SvPortSim.Verilator.Wrapper`.
  """
  @spec context(term()) :: {:ok, context()} | {:error, {:invalid_signal_specs, term()}}
  def context(signal_specs) do
    with {:ok, normalized} <- SignalSpec.normalize_many(signal_specs),
         :ok <- SignalSpec.validate_many(normalized) do
      accessors = Enum.map(normalized, &accessor_spec/1)

      {:ok,
       %{
         normalized_signal_specs: normalized,
         signal_specs_json: JsonLiteral.json(normalized),
         poke_cases: poke_cases(accessors),
         peek_cases: peek_cases(accessors)
       }}
    else
      {:error, reason} -> {:error, {:invalid_signal_specs, reason}}
    end
  end

  defp accessor_spec(%{
         "name" => name,
         "direction" => direction,
         "type" => type,
         "width" => width
       }) do
    %{
      name: name,
      field: name,
      direction: direction,
      type: type,
      width: width,
      supported?: Regex.match?(@cpp_identifier, name) and width <= @max_native_accessor_width,
      readable?: direction in ["output", "inout"],
      writable?: direction in ["input", "inout"]
    }
  end

  defp poke_cases(accessors) do
    Enum.map_join(accessors, "\n", &poke_case/1)
  end

  defp peek_cases(accessors) do
    Enum.map_join(accessors, "\n", &peek_case/1)
  end

  defp poke_case(%{name: name, supported?: false}) do
    """
    if (signal == "#{JsonLiteral.cpp_string(name)}") {
      return invalid_signal_accessor(signal, "signal shape is not supported by generated accessors");
    }
    """
  end

  defp poke_case(%{name: name, writable?: false}) do
    """
    if (signal == "#{JsonLiteral.cpp_string(name)}") {
      return invalid_signal_accessor(signal, "signal is not writable");
    }
    """
  end

  defp poke_case(%{name: name, field: field, width: width}) do
    """
    if (signal == "#{JsonLiteral.cpp_string(name)}") {
      if (!valid_two_state_encoded_value(value, #{width})) {
        return invalid_value_accessor(signal, "invalid encoded value");
      }
      auto top = session.top_model();
      top->#{field} = static_cast<decltype(top->#{field})>(bits_to_uint64(value.bits));
      session.eval();
      return ok_accessor(encode_signal(static_cast<std::uint64_t>(top->#{field}), #{width}));
    }
    """
  end

  defp peek_case(%{name: name, supported?: false}) do
    """
    if (signal == "#{JsonLiteral.cpp_string(name)}") {
      return invalid_signal_accessor(signal, "signal shape is not supported by generated accessors");
    }
    """
  end

  defp peek_case(%{name: name, readable?: false}) do
    """
    if (signal == "#{JsonLiteral.cpp_string(name)}") {
      return invalid_signal_accessor(signal, "signal is not readable");
    }
    """
  end

  defp peek_case(%{name: name, field: field, width: width}) do
    """
    if (signal == "#{JsonLiteral.cpp_string(name)}") {
      auto top = session.top_model();
      return ok_accessor(encode_signal(static_cast<std::uint64_t>(top->#{field}), #{width}));
    }
    """
  end
end
