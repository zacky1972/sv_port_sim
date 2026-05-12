defmodule SvPortSim.Verilator.Wrapper.Template do
  @moduledoc """
  Renders the interactive C++ wrapper template for Verilated top modules.

  This module owns placeholder substitution for the generated C++ runtime
  skeleton. Accessor-specific fragments are expected to be supplied by
  `SvPortSim.Verilator.Wrapper.Accessor.context/1`.
  """

  @type context :: %{
          required(:signal_specs_json) => String.t(),
          required(:poke_cases) => String.t(),
          required(:peek_cases) => String.t(),
          optional(atom()) => term()
        }

  @wrapper_source_path __DIR__ |> Path.join("../wrapper.ex") |> Path.expand()
  @external_resource @wrapper_source_path

  @wrapper_template (
                      source = File.read!(@wrapper_source_path)
                      marker = "@wrapper_template ~S\"\"\"\n"

                      rest =
                        case String.split(source, marker, parts: 2) do
                          [_prefix, rest] ->
                            rest

                          _other ->
                            raise "could not find @wrapper_template in #{@wrapper_source_path}"
                        end

                      body =
                        case String.split(rest, "\n  \"\"\"", parts: 2) do
                          [body, _suffix] ->
                            String.replace(body <> "\n", ~r/^  /m, "")

                          _other ->
                            raise "could not find @wrapper_template terminator in #{@wrapper_source_path}"
                        end

                      body
                    )

  @doc """
  Renders wrapper C++ source for `top_module` using prebuilt accessor context.
  """
  @spec render(String.t(), context()) :: String.t()
  def render(top_module, %{
        signal_specs_json: signal_specs_json,
        poke_cases: poke_cases,
        peek_cases: peek_cases
      })
      when is_binary(top_module) and is_binary(signal_specs_json) and is_binary(poke_cases) and
             is_binary(peek_cases) do
    verilated_class = "V#{top_module}"

    @wrapper_template
    |> String.replace("@@VERILATED_CLASS@@", verilated_class)
    |> String.replace("@@TOP_MODULE@@", cpp_string(top_module))
    |> String.replace("@@SIGNAL_SPECS_JSON@@", signal_specs_json)
    |> String.replace("@@POKE_CASES@@", poke_cases)
    |> String.replace("@@PEEK_CASES@@", peek_cases)
  end

  defp cpp_string(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
  end
end
