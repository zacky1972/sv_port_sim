defmodule SvPortSim.Examples.SimpleCounterTest do
  use ExUnit.Case, async: true

  @example_dir Path.expand("examples/simple_counter", File.cwd!())

  test "simple counter signal specs are valid" do
    specs = decode_json_file("signal_specs.json")

    assert :ok = SvPortSim.SignalSpec.validate_many(specs)
    assert Enum.map(specs, & &1["name"]) == ["clk", "rst_n", "enable", "count"]
  end

  test "session fixture documents reset, poke, cycle, peek, finish?, and stop" do
    session = decode_jsonl_file("session.jsonl")
    by_step = Map.new(session, &{&1["step"], &1})

    assert Enum.map(session, & &1["step"]) == [
             "reset",
             "poke",
             "cycle",
             "peek",
             "finish?",
             "stop"
           ]

    assert get_in(by_step, ["cycle", "wire", "request", "op"]) == "tick"
    assert get_in(by_step, ["cycle", "wire", "request", "body", "cycles"]) == 4

    assert get_in(by_step, ["peek", "wire", "response", "body", "value"]) == %{
             "bits" => "00000100",
             "width" => 8
           }

    assert get_in(by_step, ["finish?", "wire", "response", "body", "finished"]) == false
    assert get_in(by_step, ["stop", "wire", "request", "op"]) == "shutdown"
  end

  defp decode_json_file(file) do
    {:ok, decoded} =
      @example_dir
      |> Path.join(file)
      |> File.read!()
      |> JSON.decode()

    decoded
  end

  defp decode_jsonl_file(file) do
    @example_dir
    |> Path.join(file)
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      {:ok, decoded} = JSON.decode(line)
      decoded
    end)
  end
end
