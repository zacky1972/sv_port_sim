defmodule SvPortSim.DockerTest do
  use ExUnit.Case, async: false

  alias SvPortSim.Docker

  setup do
    tmp_dir =
      Path.join([
        System.tmp_dir!(),
        "sv_port_sim_docker_test_#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(tmp_dir)

    original_path = System.get_env("PATH")
    System.put_env("PATH", tmp_dir)

    on_exit(fn ->
      case original_path do
        nil -> System.delete_env("PATH")
        path -> System.put_env("PATH", path)
      end

      File.rm_rf(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "executable/0 returns an error when docker is not found" do
    assert Docker.executable() == {:error, :docker_not_found}
  end

  test "check/0 returns an error when docker is not found" do
    assert Docker.check() == {:error, :docker_not_found}
  end

  test "available?/0 returns false when docker is not found" do
    refute Docker.available?()
  end

  test "executable/0 returns docker path when docker command is on PATH", %{tmp_dir: tmp_dir} do
    fake_docker = write_fake_docker!(tmp_dir, successful_docker_script())

    assert Docker.executable() == {:ok, fake_docker}
  end

  test "check/0 returns client and server versions when docker is usable", %{tmp_dir: tmp_dir} do
    fake_docker = write_fake_docker!(tmp_dir, successful_docker_script())

    assert {:ok,
            %{
              executable: ^fake_docker,
              client_version: "27.3.1",
              server_version: "27.3.1"
            }} = Docker.check()
  end

  test "available?/0 returns true when docker is usable", %{tmp_dir: tmp_dir} do
    write_fake_docker!(tmp_dir, successful_docker_script())

    assert Docker.available?()
  end

  test "check/0 returns docker_unavailable when docker server is unreachable", %{tmp_dir: tmp_dir} do
    write_fake_docker!(tmp_dir, server_unavailable_script())

    assert {:error, {:docker_unavailable, 1, "Cannot connect to the Docker daemon"}} =
             Docker.check()
  end

  test "available?/0 returns false when docker server is unreachable", %{tmp_dir: tmp_dir} do
    write_fake_docker!(tmp_dir, server_unavailable_script())

    refute Docker.available?()
  end

  test "check/0 returns docker_command_failed when docker client command fails", %{
    tmp_dir: tmp_dir
  } do
    write_fake_docker!(tmp_dir, client_failure_script())

    assert {:error, {:docker_command_failed, 42, "docker client failed"}} =
             Docker.check()
  end

  defp write_fake_docker!(dir, body) do
    path = Path.join(dir, "docker")

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

    echo "unexpected docker args: $*" >&2
    exit 2
    """
  end

  defp server_unavailable_script do
    """
    if [ "$1" = "version" ] && [ "$2" = "--format" ]; then
      case "$3" in
        "{{.Client.Version}}")
          echo "27.3.1"
          exit 0
          ;;
        "{{.Server.Version}}")
          echo "Cannot connect to the Docker daemon" >&2
          exit 1
          ;;
      esac
    fi

    echo "unexpected docker args: $*" >&2
    exit 2
    """
  end

  defp client_failure_script do
    """
    if [ "$1" = "version" ] && [ "$2" = "--format" ]; then
      case "$3" in
        "{{.Client.Version}}")
          echo "docker client failed" >&2
          exit 42
          ;;
        "{{.Server.Version}}")
          echo "27.3.1"
          exit 0
          ;;
      esac
    fi

    echo "unexpected docker args: $*" >&2
    exit 2
    """
  end
end
