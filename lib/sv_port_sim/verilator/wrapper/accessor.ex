defmodule SvPortSim.Verilator.Wrapper.Accessor do
  @moduledoc """
  Builds deterministic C++ accessor fragments for generated Verilator wrappers.

  This module owns the conversion from `SvPortSim.SignalSpec` metadata to:

  * normalized signal metadata
  * JSON metadata embedded in the wrapper source
  * `poke_signal/3` dispatch cases
  * `peek_signal/2` dispatch cases
  * clock dispatch cases for `tick` and `cycle`

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
          peek_cases: String.t(),
          clock_cases: String.t(),
          default_clock_case: String.t(),
          reset_cases: String.t(),
          default_reset_case: String.t()
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
      clocks = Enum.filter(accessors, & &1.clock?)
      resets = Enum.filter(accessors, & &1.reset?)

      {:ok,
       %{
         normalized_signal_specs: normalized,
         signal_specs_json: JsonLiteral.json(normalized),
         poke_cases: poke_cases(accessors),
         peek_cases: peek_cases(accessors),
         clock_cases: clock_cases(clocks),
         default_clock_case: default_clock_case(clocks),
         reset_cases: reset_cases(resets),
         default_reset_case: default_reset_case(resets)
       }}
    else
      {:error, reason} -> {:error, {:invalid_signal_specs, reason}}
    end
  end

  defp accessor_spec(
         %{
           "name" => name,
           "direction" => direction,
           "type" => type,
           "width" => width
         } = signal_spec
       ) do
    role = Map.get(signal_spec, "role") || %{"kind" => "data"}
    role_kind = Map.get(role, "kind", "data")

    %{
      name: name,
      field: name,
      direction: direction,
      type: type,
      width: width,
      role_kind: role_kind,
      clock?: role_kind == "clock",
      clock_edge: Map.get(role, "edge"),
      reset?: role_kind == "reset",
      reset_active: Map.get(role, "active"),
      supported?: Regex.match?(@cpp_identifier, name) and width <= @max_native_accessor_width,
      readable?: direction in ["output", "inout"],
      writable?: direction in ["input", "inout"]
    }
  end

  defp poke_cases(accessors), do: Enum.map_join(accessors, "\n", &poke_case/1)
  defp peek_cases(accessors), do: Enum.map_join(accessors, "\n", &peek_case/1)
  defp clock_cases(clocks), do: Enum.map_join(clocks, "\n", &clock_case/1)
  defp reset_cases(resets), do: Enum.map_join(resets, "\n", &reset_case/1)

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
      top->#{field} = bits_to_uint64(value.bits);
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

  defp clock_case(%{name: name, supported?: false}) do
    """
    if (clock == "#{JsonLiteral.cpp_string(name)}") {
      return invalid_clock(clock, "clock shape is not supported by generated accessors");
    }
    """
  end

  defp clock_case(%{name: name, field: field, clock_edge: edge}) do
    posedge? = edge == "posedge"

    """
    if (clock == "#{JsonLiteral.cpp_string(name)}") {
      auto top = session.top_model();
      session.tick_clock([top](int value) { top->#{field} = value; }, #{cpp_bool(posedge?)});
      return ok_clock(clock);
    }
    """
  end

  defp default_clock_case([%{name: name}]) do
    """
    clock = "#{JsonLiteral.cpp_string(name)}";
    return true;
    """
  end

  defp default_clock_case(_clocks) do
    """
    return false;
    """
  end

  defp reset_case(%{name: name, supported?: false}) do
    """
    if (reset == "#{JsonLiteral.cpp_string(name)}") {
      return invalid_reset(reset, "reset shape is not supported by generated accessors");
    }
    """
  end

  defp reset_case(%{name: name, writable?: false}) do
    """
    if (reset == "#{JsonLiteral.cpp_string(name)}") {
      return invalid_reset(reset, "reset signal is not writable");
    }
    """
  end

  defp reset_case(%{name: name, field: field, reset_active: active}) do
    active_level = if active == "low", do: 0, else: 1
    inactive_level = if active == "low", do: 1, else: 0

    """
    if (reset == "#{JsonLiteral.cpp_string(name)}") {
      const int active_level = #{active_level};
      const int inactive_level = #{inactive_level};
      const int level = active ? active_level : inactive_level;
      auto top = session.top_model();
      top->#{field} = level;
      session.eval();
      return ok_reset(reset, active_level, inactive_level);
    }
    """
  end

  defp default_reset_case([%{name: name}]) do
    """
    reset = "#{JsonLiteral.cpp_string(name)}";
    return true;
    """
  end

  defp default_reset_case(_resets) do
    """
    return false;
    """
  end

  defp cpp_bool(true), do: "true"
  defp cpp_bool(false), do: "false"
end
