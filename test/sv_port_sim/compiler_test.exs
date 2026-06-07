defmodule SvPortSim.CompilerTest do
  use ExUnit.Case, async: false

  alias SvPortSim.Compiler
  alias SvPortSim.SignalSpec

  setup do
    tmp_dir =
      Path.join([
        System.tmp_dir!(),
        "sv_port_sim_compiler_test_#{System.unique_integer([:positive])}"
      ])

    bin_dir = Path.join(tmp_dir, "bin")
    wrapper_dir = Path.join(tmp_dir, "wrapper")
    work_dir = Path.join(tmp_dir, "work")

    File.mkdir_p!(bin_dir)

    original_path = System.get_env("PATH")
    original_docker = System.find_executable("docker")
    System.put_env("PATH", bin_dir)

    on_exit(fn ->
      case original_path do
        nil -> System.delete_env("PATH")
        path -> System.put_env("PATH", path)
      end

      File.rm_rf(tmp_dir)
    end)

    {
      :ok,
      tmp_dir: tmp_dir,
      bin_dir: bin_dir,
      wrapper_dir: wrapper_dir,
      work_dir: work_dir,
      original_docker: original_docker
    }
  end

  test "compile/3 expands RTL, writes wrapper, and builds executable through Docker", %{
    bin_dir: bin_dir,
    wrapper_dir: wrapper_dir,
    work_dir: work_dir
  } do
    top_module = unique_module_name("Counter")
    helper_module = unique_module_name("Helper")

    register_rtl_cleanup([top_module, helper_module])

    fake_docker = write_fake_docker!(bin_dir, successful_docker_script())

    sources = %{
      top_module => """
      module #{top_module};
      endmodule
      """,
      helper_module => """
      module #{helper_module};
      endmodule
      """
    }

    assert {:ok, result} =
             Compiler.compile(
               top_module,
               sources,
               backend: :docker,
               docker: fake_docker,
               wrapper_dir: wrapper_dir,
               work_dir: work_dir,
               image: "verilator/verilator:test",
               user: false,
               make_jobs: 2,
               verilator_args: ["-Wall"]
             )

    assert result.top_module == top_module
    assert result.executable == Path.join([work_dir, "obj_dir", "V#{top_module}"])
    assert File.exists?(result.executable)

    assert result.wrapper.file == Path.join(wrapper_dir, "#{top_module}_wrapper.cpp")
    assert File.exists?(result.wrapper.file)
    assert File.read!(result.wrapper.file) =~ ~s(#include "V#{top_module}.h")

    assert result.rtl.top_module == top_module
    assert Map.keys(result.rtl.files) |> Enum.sort() == Enum.sort([top_module, helper_module])

    assert File.read!(result.rtl.files[top_module]) =~ "module #{top_module}"
    assert File.read!(result.rtl.files[helper_module]) =~ "module #{helper_module}"

    assert result.build.top_module == top_module
    assert result.build.image == "verilator/verilator:test"
    assert result.build.docker == fake_docker
    assert result.build.work_dir == work_dir
    assert result.build.obj_dir == Path.join(work_dir, "obj_dir")
    assert result.build.executable == result.executable
    assert result.build.log =~ "fake verilator build ok"

    assert File.read!(Path.join([work_dir, "rtl", "#{top_module}.sv"])) =~
             "module #{top_module}"

    assert File.read!(Path.join([work_dir, "rtl", "#{helper_module}.sv"])) =~
             "module #{helper_module}"

    assert File.read!(Path.join([work_dir, "cpp", "#{top_module}_wrapper.cpp"])) =~
             ~s(#include "V#{top_module}.h")

    assert option_pair?(result.build.command, "--top-module", top_module)
    assert option_pair?(result.build.command, "-j", "2")
    assert "-Wall" in result.build.command
    assert "rtl/#{top_module}.sv" in result.build.command
    assert "rtl/#{helper_module}.sv" in result.build.command
    assert "cpp/#{top_module}_wrapper.cpp" in result.build.command
  end

  test "minimum generated RTL workflow is accepted by compile/3 with SignalSpec metadata", %{
    bin_dir: bin_dir,
    wrapper_dir: wrapper_dir,
    work_dir: work_dir
  } do
    top_module = unique_module_name("ExampleTop")
    helper_module = unique_module_name("ExampleXor")

    register_rtl_cleanup([top_module, helper_module])

    fake_docker = write_fake_docker!(bin_dir, successful_docker_script())
    signal_specs = minimum_workflow_signal_specs()
    sources = minimum_workflow_sources(top_module, helper_module)

    assert :ok = SignalSpec.validate_many(signal_specs)

    assert {:ok, result} =
             Compiler.compile(top_module, sources,
               backend: :docker,
               docker: fake_docker,
               wrapper_dir: wrapper_dir,
               work_dir: work_dir,
               image: "verilator/verilator:test",
               user: false,
               signal_specs: signal_specs,
               verilator_args: ["-Wall", "--timing"]
             )

    assert result.top_module == top_module
    assert result.executable == Path.join([work_dir, "obj_dir", "V#{top_module}"])
    assert File.exists?(result.executable)

    assert File.read!(result.rtl.files[top_module]) =~
             "always_ff @(posedge clk or posedge rst)"

    assert File.read!(result.rtl.files[helper_module]) =~ "assign out = lhs ^ rhs;"

    wrapper = File.read!(result.wrapper.file)

    assert wrapper =~ ~s(const char* kTopModule = "#{top_module}";)
    assert wrapper =~ "AccessorResult poke_signal"
    assert wrapper =~ "AccessorResult peek_signal"
    assert wrapper =~ "ClockResult tick_clock"
    assert wrapper =~ "ResetResult drive_reset_signal"

    for signal <- ~w(clk rst s_valid a b m_valid y) do
      assert wrapper =~ ~s("name":"#{signal}")
    end

    assert wrapper =~ ~s|if (clock == "clk")|
    assert wrapper =~ "top->clk = value;"
    assert wrapper =~ ~s|if (reset == "rst")|
    assert wrapper =~ "top->rst = level;"

    assert wrapper =~ ~s|if (signal == "s_valid")|
    assert wrapper =~ ~s|if (signal == "a")|
    assert wrapper =~ ~s|if (signal == "b")|
    assert wrapper =~ ~s|if (signal == "m_valid")|
    assert wrapper =~ ~s|if (signal == "y")|
    assert wrapper =~ "encode_signal(static_cast<std::uint64_t>(top->y), 8)"

    assert result.build.log =~ "fake verilator build ok"
    assert option_pair?(result.build.command, "--top-module", top_module)
    assert "-Wall" in result.build.command
    assert "--timing" in result.build.command
    assert "rtl/#{top_module}.sv" in result.build.command
    assert "rtl/#{helper_module}.sv" in result.build.command
    assert "cpp/#{top_module}_wrapper.cpp" in result.build.command
  end

  test "README documents the minimum generated RTL compile-and-run workflow" do
    readme = File.read!(Path.expand("../../README.md", __DIR__))

    required_fragments = [
      "SvPortSim.Compiler.compile",
      "SvPortSim.SignalSpec.clock",
      "SvPortSim.SignalSpec.reset",
      "SvPortSim.SignalSpec.data",
      "SvPortSim.start_link",
      "SvPortSim.reset",
      "SvPortSim.poke",
      "SvPortSim.tick",
      "SvPortSim.peek",
      "SvPortSim.stop",
      "%{bits: \"00001111\", width: 8}",
      "Supported SystemVerilog subset"
    ]

    for fragment <- required_fragments do
      assert readme =~ fragment
    end
  end

  if System.get_env("SV_PORT_SIM_RUN_VERILATOR_TESTS") == "1" do
    @tag :verilator
    test "minimum generated RTL workflow compiles and runs through real Verilator", %{
      original_docker: original_docker
    } do
      docker = System.get_env("SV_PORT_SIM_DOCKER") || original_docker

      if is_nil(docker) do
        flunk("SV_PORT_SIM_RUN_VERILATOR_TESTS=1 was set, but no docker executable was found")
      end

      if !docker_daemon_available?(docker) do
        flunk(
          "SV_PORT_SIM_RUN_VERILATOR_TESTS=1 was set, but Docker is not reachable through #{docker}"
        )
      end

      top_module = unique_module_name("ExampleTopReal")
      helper_module = unique_module_name("ExampleXorReal")

      register_rtl_cleanup([top_module, helper_module])

      {wrapper_dir, work_dir} = docker_bindable_build_dirs(top_module)

      signal_specs = minimum_workflow_signal_specs()
      sources = minimum_workflow_sources(top_module, helper_module)

      assert :ok = SignalSpec.validate_many(signal_specs)

      assert {:ok, result} =
               Compiler.compile(top_module, sources,
                 backend: :docker,
                 docker: docker,
                 signal_specs: signal_specs,
                 wrapper_dir: wrapper_dir,
                 work_dir: work_dir,
                 image:
                   System.get_env("SV_PORT_SIM_VERILATOR_IMAGE") || "verilator/verilator:latest",
                 user: false,
                 verilator_args: ["-Wno-fatal"]
               )

      assert File.exists?(result.executable)

      {:ok, sim} = SvPortSim.start_link(executable: result.executable)

      on_exit(fn ->
        if Process.alive?(sim) do
          SvPortSim.stop(sim)
        end
      end)

      assert {:ok, _} = SvPortSim.reset(sim, cycles: 2, clock: "clk", reset: "rst")

      assert {:ok, %{"value" => %{"bits" => "0", "width" => 1}}} =
               SvPortSim.peek(sim, "m_valid")

      assert {:ok, %{"value" => %{"bits" => "00000000", "width" => 8}}} =
               SvPortSim.peek(sim, "y")

      assert {:ok, _} = SvPortSim.poke(sim, "s_valid", %{bits: "1", width: 1})
      assert {:ok, _} = SvPortSim.poke(sim, "a", %{bits: "00001111", width: 8})
      assert {:ok, _} = SvPortSim.poke(sim, "b", %{bits: "11110000", width: 8})
      assert {:ok, _} = SvPortSim.tick(sim, cycles: 1, clock: "clk")

      assert {:ok, %{"value" => %{"bits" => "1", "width" => 1}}} =
               SvPortSim.peek(sim, "m_valid")

      assert {:ok, %{"value" => %{"bits" => "11111111", "width" => 8}}} =
               SvPortSim.peek(sim, "y")

      assert {:ok, _} = SvPortSim.poke(sim, "s_valid", %{bits: "0", width: 1})
      assert {:ok, _} = SvPortSim.poke(sim, "a", %{bits: "00000000", width: 8})
      assert {:ok, _} = SvPortSim.poke(sim, "b", %{bits: "11111111", width: 8})
      assert {:ok, _} = SvPortSim.tick(sim, cycles: 1, clock: "clk")

      assert {:ok, %{"value" => %{"bits" => "0", "width" => 1}}} =
               SvPortSim.peek(sim, "m_valid")

      assert {:ok, _} = SvPortSim.poke(sim, "s_valid", %{bits: "1", width: 1})
      assert {:ok, _} = SvPortSim.poke(sim, "a", %{bits: "10101010", width: 8})
      assert {:ok, _} = SvPortSim.poke(sim, "b", %{bits: "11001100", width: 8})
      assert {:ok, _} = SvPortSim.tick(sim, cycles: 1, clock: "clk")

      assert {:ok, %{"value" => %{"bits" => "1", "width" => 1}}} =
               SvPortSim.peek(sim, "m_valid")

      assert {:ok, %{"value" => %{"bits" => "01100110", "width" => 8}}} =
               SvPortSim.peek(sim, "y")

      :ok = SvPortSim.stop(sim)

      assert result.build.work_dir == work_dir

      assert result.build.command
             |> Enum.any?(&String.starts_with?(&1, "type=bind,source=#{work_dir},"))
    end

    defp docker_bindable_build_dirs(top_module) do
      root =
        Path.expand(
          Path.join([
            "_build",
            "sv_port_sim",
            "compiler_test",
            "real_verilator",
            top_module
          ])
        )

      File.rm_rf!(root)
      on_exit(fn -> File.rm_rf(root) end)

      {Path.join(root, "wrapper"), Path.join(root, "work")}
    end

    defp docker_daemon_available?(docker) do
      case System.cmd(docker, ["version", "--format", "{{.Server.Version}}"],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> true
        {_output, _status} -> false
      end
    rescue
      _ in ErlangError -> false
    end
  else
    @tag :verilator
    @tag skip:
           "set SV_PORT_SIM_RUN_VERILATOR_TESTS=1 to compile and run generated RTL through real Docker/Verilator"
    test "minimum generated RTL workflow compiles and runs through real Verilator" do
      :ok
    end
  end

  test "compile/3 rejects unsupported backend", %{
    wrapper_dir: wrapper_dir,
    work_dir: work_dir
  } do
    top_module = unique_module_name("Counter")
    register_rtl_cleanup([top_module])

    sources = %{
      top_module => "module #{top_module}; endmodule\n"
    }

    assert Compiler.compile(
             top_module,
             sources,
             backend: :native,
             wrapper_dir: wrapper_dir,
             work_dir: work_dir
           ) == {:error, {:unsupported_backend, :native}}
  end

  test "compile/3 propagates RTL validation error when top module is missing", %{
    wrapper_dir: wrapper_dir,
    work_dir: work_dir
  } do
    top_module = unique_module_name("Counter")
    other_module = unique_module_name("Other")

    sources = %{
      other_module => "module #{other_module}; endmodule\n"
    }

    assert Compiler.compile(
             top_module,
             sources,
             backend: :docker,
             wrapper_dir: wrapper_dir,
             work_dir: work_dir
           ) == {:error, {:top_module_not_found, top_module}}
  end

  test "compile/3 propagates Docker build failure", %{
    bin_dir: bin_dir,
    wrapper_dir: wrapper_dir,
    work_dir: work_dir
  } do
    top_module = unique_module_name("Counter")
    register_rtl_cleanup([top_module])

    fake_docker = write_fake_docker!(bin_dir, failing_docker_run_script())

    sources = %{
      top_module => "module #{top_module}; endmodule\n"
    }

    assert {:error, {:verilator_docker_failed, 66, "verilator failed", command}} =
             Compiler.compile(
               top_module,
               sources,
               backend: :docker,
               docker: fake_docker,
               wrapper_dir: wrapper_dir,
               work_dir: work_dir,
               user: false
             )

    assert [^fake_docker, "run" | _] = command
    assert option_pair?(command, "--top-module", top_module)
  end

  test "compile/3 returns docker_not_found when docker is unavailable", %{
    wrapper_dir: wrapper_dir,
    work_dir: work_dir
  } do
    top_module = unique_module_name("Counter")
    register_rtl_cleanup([top_module])

    sources = %{
      top_module => "module #{top_module}; endmodule\n"
    }

    assert Compiler.compile(
             top_module,
             sources,
             backend: :docker,
             wrapper_dir: wrapper_dir,
             work_dir: work_dir,
             user: false
           ) == {:error, :docker_not_found}
  end

  test "compile/3 rejects invalid arguments" do
    assert Compiler.compile(:not_a_module_name, %{}) ==
             {:error, {:invalid_arguments, :not_a_module_name, %{}}}

    assert Compiler.compile("Counter", []) ==
             {:error, {:invalid_arguments, "Counter", []}}
  end

  defp minimum_workflow_signal_specs do
    [
      SignalSpec.clock("clk", type: "logic"),
      SignalSpec.reset("rst", type: "logic", active: "high"),
      SignalSpec.data("s_valid", "input", "logic", 1),
      SignalSpec.data("a", "input", "logic", 8),
      SignalSpec.data("b", "input", "logic", 8),
      SignalSpec.data("m_valid", "output", "logic", 1),
      SignalSpec.data("y", "output", "logic", 8)
    ]
  end

  defp minimum_workflow_sources(top_module, helper_module) do
    %{
      helper_module => """
      module #{helper_module}(
        input  logic [7:0] lhs,
        input  logic [7:0] rhs,
        output logic [7:0] out
      );
        assign out = lhs ^ rhs;
      endmodule
      """,
      top_module => """
      module #{top_module}(
        input  logic       clk,
        input  logic       rst,
        input  logic       s_valid,
        input  logic [7:0] a,
        input  logic [7:0] b,
        output logic       m_valid,
        output logic [7:0] y
      );
        logic [7:0] next_y;

        #{helper_module} u_xor(
          .lhs(a),
          .rhs(b),
          .out(next_y)
        );

        always_ff @(posedge clk or posedge rst) begin
          if (rst) begin
            m_valid <= 1'b0;
            y       <= 8'h00;
          end else begin
            m_valid <= s_valid;

            if (s_valid) begin
              y <= next_y;
            end
          end
        end
      endmodule
      """
    }
  end

  defp unique_module_name(prefix) do
    "#{prefix}#{System.unique_integer([:positive])}"
  end

  defp register_rtl_cleanup(module_names) do
    on_exit(fn ->
      rtl_dir = Application.app_dir(:sv_port_sim, "rtl")

      Enum.each(module_names, fn module_name ->
        File.rm(Path.join(rtl_dir, "#{module_name}.sv"))
      end)
    end)
  end

  defp write_fake_docker!(bin_dir, body) do
    path = Path.join(bin_dir, "docker")

    File.write!(path, "#!/bin/sh\n" <> body)
    :ok = File.chmod(path, 0o755)

    path
  end

  defp option_pair?(command, option, value) do
    command
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn
      [^option, ^value] -> true
      _ -> false
    end)
  end

  defp successful_docker_script do
    """
    if [ "$1" = "version" ] && [ "$2" = "--format" ]; then
      case "$3" in
        "{{.Client.Version}}")
          echo "27.3.1"
          exit 0
          ;;
        "{{.Server.Version}}")
          echo "27.3.1"
          exit 0
          ;;
      esac
    fi

    if [ "$1" = "run" ]; then
      mount=""
      top=""
      previous=""

      for arg in "$@"; do
        if [ "$previous" = "--mount" ]; then
          mount="$arg"
        fi

        if [ "$previous" = "--top-module" ]; then
          top="$arg"
        fi

        previous="$arg"
      done

      source="${mount#type=bind,source=}"
      source="${source%,target=/work}"

      if [ -z "$source" ] || [ -z "$top" ]; then
        echo "missing mount or top module" >&2
        exit 17
      fi

      /bin/mkdir -p "$source/obj_dir"
      : > "$source/obj_dir/V$top"

      echo "fake verilator build ok"
      exit 0
    fi

    echo "unexpected docker args: $*" >&2
    exit 2
    """
  end

  defp failing_docker_run_script do
    """
    if [ "$1" = "version" ] && [ "$2" = "--format" ]; then
      echo "27.3.1"
      exit 0
    fi

    if [ "$1" = "run" ]; then
      echo "verilator failed" >&2
      exit 66
    fi

    echo "unexpected docker args: $*" >&2
    exit 2
    """
  end
end
