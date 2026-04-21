defmodule SvPortSim.Verilator.DockerTest do
  use ExUnit.Case, async: false

  alias SvPortSim.Verilator.Docker, as: VerilatorDocker

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
