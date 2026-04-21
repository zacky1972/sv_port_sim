defmodule SvPortSim.CompilerTest do
  use ExUnit.Case, async: false

  alias SvPortSim.Compiler

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
    System.put_env("PATH", bin_dir)

    on_exit(fn ->
      case original_path do
        nil -> System.delete_env("PATH")
        path -> System.put_env("PATH", path)
      end

      File.rm_rf(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, bin_dir: bin_dir, wrapper_dir: wrapper_dir, work_dir: work_dir}
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
