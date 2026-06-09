defmodule SvPortSim.Verilator.DockerTest do
  use ExUnit.Case, async: false

  alias SvPortSim.Verilator.Docker, as: VerilatorDocker
  alias SvPortSim.Verilator.DockerWorker

  setup do
    tmp_dir =
      Path.join([
        System.tmp_dir!(),
        "sv_port_sim_verilator_docker_test_#{System.unique_integer([:positive])}"
      ])

    bin_dir = Path.join(tmp_dir, "bin")
    input_dir = Path.join(tmp_dir, "input")
    work_dir = Path.join(tmp_dir, "work")

    File.mkdir_p!(bin_dir)
    File.mkdir_p!(input_dir)

    original_path = System.get_env("PATH")
    System.put_env("PATH", bin_dir)

    on_exit(fn ->
      case original_path do
        nil -> System.delete_env("PATH")
        path -> System.put_env("PATH", path)
      end

      File.rm_rf(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, bin_dir: bin_dir, input_dir: input_dir, work_dir: work_dir}
  end

  test "default_work_dir/1 returns application-local Verilator work directory" do
    assert VerilatorDocker.default_work_dir("Counter") ==
             Application.app_dir(:sv_port_sim, Path.join(["verilator", "Counter"]))
  end

  test "compile_executable/4 builds executable through docker", %{
    bin_dir: bin_dir,
    input_dir: input_dir,
    work_dir: work_dir
  } do
    fake_docker = write_fake_docker!(bin_dir, successful_docker_script())

    source_file =
      write_input_file!(
        input_dir,
        "rtl_src/Counter.sv",
        """
        module Counter;
        endmodule
        """
      )

    wrapper_cpp =
      write_input_file!(
        input_dir,
        "cpp_src/counter_wrapper.cpp",
        """
        #include "VCounter.h"
        int main() { return 0; }
        """
      )

    assert {:ok, build} =
             VerilatorDocker.compile_executable(
               "Counter",
               [source_file],
               wrapper_cpp,
               docker: fake_docker,
               work_dir: work_dir,
               image: "verilator/verilator:test",
               user: false,
               extra_args: ["-Wall"]
             )

    assert build.top_module == "Counter"
    assert build.image == "verilator/verilator:test"
    assert build.docker == fake_docker
    assert build.work_dir == work_dir
    assert build.obj_dir == Path.join(work_dir, "obj_dir")
    assert build.executable == Path.join([work_dir, "obj_dir", "VCounter"])
    assert File.exists?(build.executable)

    assert File.read!(Path.join([work_dir, "rtl", "Counter.sv"])) =~ "module Counter"
    assert File.read!(Path.join([work_dir, "cpp", "counter_wrapper.cpp"])) =~ "int main"

    assert build.command == [
             fake_docker,
             "run",
             "--rm",
             "--mount",
             "type=bind,source=#{work_dir},target=/work",
             "--workdir",
             "/work",
             "verilator/verilator:test",
             "--cc",
             "--exe",
             "--build",
             "-j",
             "0",
             "--Mdir",
             "obj_dir",
             "--top-module",
             "Counter",
             "-Wall",
             "cpp/counter_wrapper.cpp",
             "rtl/Counter.sv"
           ]

    assert build.log =~ "fake verilator build ok"
  end

  test "lint/3 runs Verilator lint-only without wrapper or executable", %{
    bin_dir: bin_dir,
    input_dir: input_dir,
    work_dir: work_dir
  } do
    fake_docker = write_fake_docker!(bin_dir, successful_lint_script())
    source_file = write_input_file!(input_dir, "Counter.sv", "module Counter; endmodule\n")

    assert {:ok, lint} =
             VerilatorDocker.lint(
               "Counter",
               [source_file],
               docker: fake_docker,
               work_dir: work_dir,
               image: "verilator/verilator:test",
               user: false,
               extra_args: ["-Wall"]
             )

    assert lint.mode == :lint_only
    assert lint.top_module == "Counter"
    assert lint.image == "verilator/verilator:test"
    assert lint.docker == fake_docker
    assert lint.work_dir == work_dir
    assert lint.obj_dir == Path.join(work_dir, "obj_dir")
    refute Map.has_key?(lint, :executable)
    assert File.read!(Path.join([work_dir, "rtl", "Counter.sv"])) =~ "module Counter"
    refute File.exists?(Path.join(work_dir, "cpp"))

    assert lint.command == [
             fake_docker,
             "run",
             "--rm",
             "--mount",
             "type=bind,source=#{work_dir},target=/work",
             "--workdir",
             "/work",
             "verilator/verilator:test",
             "--lint-only",
             "--Mdir",
             "obj_dir",
             "--top-module",
             "Counter",
             "-Wall",
             "rtl/Counter.sv"
           ]

    assert lint.log =~ "fake verilator lint ok"
  end

  test "lint/3 returns structured lint failure", %{
    bin_dir: bin_dir,
    input_dir: input_dir,
    work_dir: work_dir
  } do
    fake_docker = write_fake_docker!(bin_dir, failing_lint_script())
    source_file = write_input_file!(input_dir, "Counter.sv", "module Counter; endmodule\n")

    assert {:error, {:verilator_lint_failed, 65, "lint failed", command}} =
             VerilatorDocker.lint(
               "Counter",
               [source_file],
               docker: fake_docker,
               work_dir: work_dir,
               user: false
             )

    assert [^fake_docker, "run" | _] = command
    assert "--lint-only" in command
    refute "--build" in command
  end

  test "compile_executable/4 can reuse a persistent docker worker", %{
    bin_dir: bin_dir,
    input_dir: input_dir,
    tmp_dir: tmp_dir,
    work_dir: work_dir
  } do
    log_file = Path.join(tmp_dir, "docker_calls")
    fake_docker = write_fake_docker!(bin_dir, persistent_worker_docker_script(work_dir, log_file))
    source_file = write_input_file!(input_dir, "Counter.sv", "module Counter; endmodule\n")
    wrapper_cpp = write_input_file!(input_dir, "wrapper.cpp", "int main() { return 0; }\n")
    worker_name = "sv_port_sim_test_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      case :global.whereis_name({DockerWorker, worker_name}) do
        :undefined -> :ok
        pid -> DockerWorker.stop(pid)
      end
    end)

    assert {:ok, first} =
             VerilatorDocker.compile_executable(
               "Counter",
               [source_file],
               wrapper_cpp,
               docker: fake_docker,
               work_dir: work_dir,
               user: false,
               docker_mode: :persistent,
               docker_worker_name: worker_name,
               docker_worker_cleanup: :on_exit
             )

    assert {:ok, second} =
             VerilatorDocker.compile_executable(
               "Counter",
               [source_file],
               wrapper_cpp,
               docker: fake_docker,
               work_dir: work_dir,
               user: false,
               docker_mode: :persistent,
               docker_worker_name: worker_name,
               docker_worker_cleanup: :on_exit
             )

    assert first.container_name == worker_name
    assert second.container_name == worker_name
    assert File.exists?(first.executable)
    assert File.exists?(second.executable)

    calls = File.read!(log_file) |> String.split("\n", trim: true)
    assert Enum.count(calls, &(&1 == "run")) == 1
    assert Enum.count(calls, &(&1 == "exec")) == 2
  end

  test "compile_executable/4 accepts make_jobs option", %{
    bin_dir: bin_dir,
    input_dir: input_dir,
    work_dir: work_dir
  } do
    fake_docker = write_fake_docker!(bin_dir, successful_docker_script())
    source_file = write_input_file!(input_dir, "Counter.sv", "module Counter; endmodule\n")
    wrapper_cpp = write_input_file!(input_dir, "wrapper.cpp", "int main() { return 0; }\n")

    assert {:ok, build} =
             VerilatorDocker.compile_executable(
               "Counter",
               [source_file],
               wrapper_cpp,
               docker: fake_docker,
               work_dir: work_dir,
               user: false,
               make_jobs: 4
             )

    assert build.command |> Enum.chunk_every(2, 1, :discard) |> Enum.member?(["-j", "4"])
  end

  test "compile_executable/4 returns docker_not_found when docker is not on PATH", %{
    input_dir: input_dir,
    work_dir: work_dir
  } do
    source_file = write_input_file!(input_dir, "Counter.sv", "module Counter; endmodule\n")
    wrapper_cpp = write_input_file!(input_dir, "wrapper.cpp", "int main() { return 0; }\n")

    assert VerilatorDocker.compile_executable(
             "Counter",
             [source_file],
             wrapper_cpp,
             work_dir: work_dir,
             user: false
           ) == {:error, :docker_not_found}
  end

  test "compile_executable/4 returns docker_unavailable when daemon check fails", %{
    bin_dir: bin_dir,
    input_dir: input_dir,
    work_dir: work_dir
  } do
    fake_docker = write_fake_docker!(bin_dir, docker_unavailable_script())
    source_file = write_input_file!(input_dir, "Counter.sv", "module Counter; endmodule\n")
    wrapper_cpp = write_input_file!(input_dir, "wrapper.cpp", "int main() { return 0; }\n")

    assert VerilatorDocker.compile_executable(
             "Counter",
             [source_file],
             wrapper_cpp,
             docker: fake_docker,
             work_dir: work_dir,
             user: false
           ) ==
             {:error, {:docker_unavailable, 1, "Cannot connect to the Docker daemon"}}

    refute File.exists?(work_dir)
  end

  test "compile_executable/4 can skip docker daemon precheck", %{
    bin_dir: bin_dir,
    input_dir: input_dir,
    work_dir: work_dir
  } do
    fake_docker = write_fake_docker!(bin_dir, successful_run_but_failing_version_script())
    source_file = write_input_file!(input_dir, "Counter.sv", "module Counter; endmodule\n")
    wrapper_cpp = write_input_file!(input_dir, "wrapper.cpp", "int main() { return 0; }\n")

    assert {:ok, build} =
             VerilatorDocker.compile_executable(
               "Counter",
               [source_file],
               wrapper_cpp,
               docker: fake_docker,
               work_dir: work_dir,
               user: false,
               check_docker: false
             )

    assert File.exists?(build.executable)
  end

  test "compile_executable/4 returns verilator_docker_failed when docker run fails", %{
    bin_dir: bin_dir,
    input_dir: input_dir,
    work_dir: work_dir
  } do
    fake_docker = write_fake_docker!(bin_dir, failing_docker_run_script())
    source_file = write_input_file!(input_dir, "Counter.sv", "module Counter; endmodule\n")
    wrapper_cpp = write_input_file!(input_dir, "wrapper.cpp", "int main() { return 0; }\n")

    assert {:error, {:verilator_docker_failed, 66, "verilator failed", command}} =
             VerilatorDocker.compile_executable(
               "Counter",
               [source_file],
               wrapper_cpp,
               docker: fake_docker,
               work_dir: work_dir,
               user: false
             )

    assert [^fake_docker, "run" | _] = command
  end

  test "compile_executable/4 returns executable_not_found when build succeeds but output is missing",
       %{
         bin_dir: bin_dir,
         input_dir: input_dir,
         work_dir: work_dir
       } do
    fake_docker = write_fake_docker!(bin_dir, no_executable_script())
    source_file = write_input_file!(input_dir, "Counter.sv", "module Counter; endmodule\n")
    wrapper_cpp = write_input_file!(input_dir, "wrapper.cpp", "int main() { return 0; }\n")

    assert {:error,
            {:executable_not_found, executable, "build finished without executable", _command}} =
             VerilatorDocker.compile_executable(
               "Counter",
               [source_file],
               wrapper_cpp,
               docker: fake_docker,
               work_dir: work_dir,
               user: false
             )

    assert executable == Path.join([work_dir, "obj_dir", "VCounter"])
  end

  test "compile_executable/4 can skip executable verification", %{
    bin_dir: bin_dir,
    input_dir: input_dir,
    work_dir: work_dir
  } do
    fake_docker = write_fake_docker!(bin_dir, no_executable_script())
    source_file = write_input_file!(input_dir, "Counter.sv", "module Counter; endmodule\n")
    wrapper_cpp = write_input_file!(input_dir, "wrapper.cpp", "int main() { return 0; }\n")

    assert {:ok, build} =
             VerilatorDocker.compile_executable(
               "Counter",
               [source_file],
               wrapper_cpp,
               docker: fake_docker,
               work_dir: work_dir,
               user: false,
               verify_executable: false
             )

    refute File.exists?(build.executable)
  end

  test "compile_executable/4 rejects invalid top module", %{
    bin_dir: bin_dir,
    input_dir: input_dir,
    work_dir: work_dir
  } do
    fake_docker = write_fake_docker!(bin_dir, successful_docker_script())
    source_file = write_input_file!(input_dir, "Counter.sv", "module Counter; endmodule\n")
    wrapper_cpp = write_input_file!(input_dir, "wrapper.cpp", "int main() { return 0; }\n")

    assert VerilatorDocker.compile_executable(
             "../Counter",
             [source_file],
             wrapper_cpp,
             docker: fake_docker,
             work_dir: work_dir,
             user: false
           ) == {:error, {:invalid_top_module, "../Counter"}}
  end

  test "compile_executable/4 rejects empty source files", %{
    bin_dir: bin_dir,
    input_dir: input_dir,
    work_dir: work_dir
  } do
    fake_docker = write_fake_docker!(bin_dir, successful_docker_script())
    wrapper_cpp = write_input_file!(input_dir, "wrapper.cpp", "int main() { return 0; }\n")

    assert VerilatorDocker.compile_executable(
             "Counter",
             [],
             wrapper_cpp,
             docker: fake_docker,
             work_dir: work_dir,
             user: false
           ) == {:error, :empty_source_files}
  end

  test "compile_executable/4 rejects missing source file", %{
    bin_dir: bin_dir,
    input_dir: input_dir,
    work_dir: work_dir
  } do
    fake_docker = write_fake_docker!(bin_dir, successful_docker_script())
    missing_source = Path.join(input_dir, "missing.sv")
    wrapper_cpp = write_input_file!(input_dir, "wrapper.cpp", "int main() { return 0; }\n")

    assert VerilatorDocker.compile_executable(
             "Counter",
             [missing_source],
             wrapper_cpp,
             docker: fake_docker,
             work_dir: work_dir,
             user: false
           ) == {:error, {:source_not_found, missing_source}}
  end

  test "compile_executable/4 rejects missing wrapper file", %{
    bin_dir: bin_dir,
    input_dir: input_dir,
    work_dir: work_dir
  } do
    fake_docker = write_fake_docker!(bin_dir, successful_docker_script())
    source_file = write_input_file!(input_dir, "Counter.sv", "module Counter; endmodule\n")
    missing_wrapper = Path.join(input_dir, "missing.cpp")

    assert VerilatorDocker.compile_executable(
             "Counter",
             [source_file],
             missing_wrapper,
             docker: fake_docker,
             work_dir: work_dir,
             user: false
           ) == {:error, {:wrapper_not_found, missing_wrapper}}
  end

  test "compile_executable/4 rejects duplicate source basenames", %{
    bin_dir: bin_dir,
    input_dir: input_dir,
    work_dir: work_dir
  } do
    fake_docker = write_fake_docker!(bin_dir, successful_docker_script())

    source_file_1 = write_input_file!(input_dir, "a/Counter.sv", "module Counter; endmodule\n")
    source_file_2 = write_input_file!(input_dir, "b/Counter.sv", "module Counter2; endmodule\n")
    wrapper_cpp = write_input_file!(input_dir, "wrapper.cpp", "int main() { return 0; }\n")

    assert VerilatorDocker.compile_executable(
             "Counter",
             [source_file_1, source_file_2],
             wrapper_cpp,
             docker: fake_docker,
             work_dir: work_dir,
             user: false
           ) == {:error, {:duplicate_source_basenames, ["Counter.sv", "Counter.sv"]}}
  end

  defp write_input_file!(base_dir, relative_path, contents) do
    path = Path.join(base_dir, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  defp write_fake_docker!(bin_dir, body) do
    path = Path.join(bin_dir, "docker")

    File.write!(path, "#!/bin/sh\n" <> body)
    :ok = File.chmod(path, 0o755)

    path
  end

  defp successful_lint_script do
    """
    if [ "$1" = "version" ] && [ "$2" = "--format" ]; then
      echo "27.3.1"
      exit 0
    fi

    if [ "$1" = "run" ]; then
      lint="no"
      build="no"

      for arg in "$@"; do
        if [ "$arg" = "--lint-only" ]; then
          lint="yes"
        fi

        if [ "$arg" = "--build" ]; then
          build="yes"
        fi
      done

      if [ "$lint" != "yes" ] || [ "$build" = "yes" ]; then
        echo "expected lint-only docker run" >&2
        exit 18
      fi

      echo "fake verilator lint ok"
      exit 0
    fi

    echo "unexpected docker args: $*" >&2
    exit 2
    """
  end

  defp failing_lint_script do
    """
    if [ "$1" = "version" ] && [ "$2" = "--format" ]; then
      echo "27.3.1"
      exit 0
    fi

    if [ "$1" = "run" ]; then
      echo "lint failed" >&2
      exit 65
    fi

    echo "unexpected docker args: $*" >&2
    exit 2
    """
  end

  defp persistent_worker_docker_script(work_dir, log_file) do
    """
    if [ "$1" = "version" ] && [ "$2" = "--format" ]; then
      echo "27.3.1"
      exit 0
    fi

    if [ "$1" = "inspect" ]; then
      exit 1
    fi

    if [ "$1" = "run" ]; then
      echo "run" >> #{log_file}
      echo "container-id-1"
      exit 0
    fi

    if [ "$1" = "exec" ]; then
      echo "exec" >> #{log_file}
      top=""
      previous=""

      for arg in "$@"; do
        if [ "$previous" = "--top-module" ]; then
          top="$arg"
        fi

        previous="$arg"
      done

      if [ -z "$top" ]; then
        echo "missing top module" >&2
        exit 19
      fi

      /bin/mkdir -p #{work_dir}/obj_dir
      : > #{work_dir}/obj_dir/V$top

      echo "fake persistent verilator build ok"
      exit 0
    fi

    if [ "$1" = "rm" ]; then
      echo "rm" >> #{log_file}
      exit 0
    fi

    echo "unexpected docker args: $*" >&2
    exit 2
    """
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

  defp docker_unavailable_script do
    """
    if [ "$1" = "version" ] && [ "$2" = "--format" ]; then
      case "$3" in
        "{{.Server.Version}}")
          echo "Cannot connect to the Docker daemon" >&2
          exit 1
          ;;
        "{{.Client.Version}}")
          echo "27.3.1"
          exit 0
          ;;
      esac
    fi

    echo "unexpected docker args: $*" >&2
    exit 2
    """
  end

  defp successful_run_but_failing_version_script do
    """
    if [ "$1" = "version" ] && [ "$2" = "--format" ]; then
      echo "version command intentionally failed" >&2
      exit 1
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

  defp no_executable_script do
    """
    if [ "$1" = "version" ] && [ "$2" = "--format" ]; then
      echo "27.3.1"
      exit 0
    fi

    if [ "$1" = "run" ]; then
      echo "build finished without executable"
      exit 0
    fi

    echo "unexpected docker args: $*" >&2
    exit 2
    """
  end
end
