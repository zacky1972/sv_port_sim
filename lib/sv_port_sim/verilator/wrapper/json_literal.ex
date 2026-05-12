defmodule SvPortSim.Verilator.Wrapper.JsonLiteral do
  @moduledoc """
  Encodes deterministic JSON literals and escaped C++ string-literal bodies for
  generated Verilator wrapper sources.

  `json/1` intentionally supports only the value shapes emitted by the wrapper
  generator: nil, booleans, integers, strings, lists, and maps. Map keys are
  stringified and sorted so generated metadata is deterministic.

  `cpp_string/1` escapes a string body for insertion inside an existing C++
  string literal. It does not add surrounding quotes.
  """

  @type json_value ::
          nil
          | boolean()
          | integer()
          | String.t()
          | [json_value()]
          | %{optional(term()) => json_value()}

  @doc """
  Encodes a deterministic compact JSON literal.
  """
  @spec json(json_value()) :: String.t()
  def json(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &json/1) <> "]"
  end

  def json(%{} = value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map(fn {key, item} -> json_string(to_string(key)) <> ":" <> json(item) end)

    "{" <> Enum.join(entries, ",") <> "}"
  end

  def json(value) when is_binary(value), do: json_string(value)
  def json(value) when is_integer(value), do: Integer.to_string(value)
  def json(value) when is_boolean(value), do: if(value, do: "true", else: "false")
  def json(nil), do: "null"

  @doc """
  Escapes a string body for insertion inside a C++ string literal.

  The returned value is not surrounded with quotes.
  """
  @spec cpp_string(String.t()) :: String.t()
  def cpp_string(value) when is_binary(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.map_join(&cpp_string_byte/1)
  end

  defp json_string(value) do
    ~s(") <> json_escape(value) <> ~s(")
  end

  defp json_escape(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.map_join(&json_byte/1)
  end

  defp json_byte(?"), do: ~S(\")
  defp json_byte(?\\), do: ~S(\\)
  defp json_byte(?\b), do: ~S(\b)
  defp json_byte(?\f), do: ~S(\f)
  defp json_byte(?\n), do: ~S(\n)
  defp json_byte(?\r), do: ~S(\r)
  defp json_byte(?\t), do: ~S(\t)

  defp json_byte(byte) when byte < 0x20 do
    "\\u00" <> (byte |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0"))
  end

  defp json_byte(byte), do: <<byte>>

  defp cpp_string_byte(?"), do: ~S(\")
  defp cpp_string_byte(?\\), do: ~S(\\)
  defp cpp_string_byte(?\b), do: ~S(\b)
  defp cpp_string_byte(?\f), do: ~S(\f)
  defp cpp_string_byte(?\n), do: ~S(\n)
  defp cpp_string_byte(?\r), do: ~S(\r)
  defp cpp_string_byte(?\t), do: ~S(\t)
  defp cpp_string_byte(byte), do: <<byte>>
end
