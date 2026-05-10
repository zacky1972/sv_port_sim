defmodule SvPortSim.Docker do
  @moduledoc """
  Detects whether Docker is installed and usable on the host system.

  This module provides a small probe for Docker availability. It checks both
  the Docker client executable and the Docker daemon because a host may have
  the `docker` command installed while the daemon is stopped, unreachable, or
  inaccessible to the current user.

  `executable/0` only checks whether the `docker` executable can be found in
  `PATH`. `check/0` performs the full availability check by running Docker
  version commands and collecting the client and server versions. `available?/0`
  is a boolean convenience wrapper around `check/0`.

  The functions in this module do not install Docker, start the Docker daemon,
  or modify Docker state.
  """

  @type check_result ::
          {:ok,
           %{
             executable: Path.t(),
             client_version: String.t() | nil,
             server_version: String.t() | nil
           }}
          | {:error, reason()}

  @type reason ::
          :docker_not_found
          | {:docker_command_failed, non_neg_integer(), String.t()}
          | {:docker_unavailable, non_neg_integer(), String.t()}

  @doc """
  Returns the path to the Docker executable.

  This function searches for `docker` in the current process `PATH` by using
  `System.find_executable/1`.

  Returns `{:ok, path}` when the executable is found.

  Returns `{:error, :docker_not_found}` when the executable is not available in
  `PATH`.

  This function does not check whether the Docker daemon is running. Use
  `check/0` or `available?/0` when daemon connectivity also matters.
  """
  @spec executable() :: {:ok, Path.t()} | {:error, :docker_not_found}
  def executable() do
    case System.find_executable("docker") do
      nil -> {:error, :docker_not_found}
      path -> {:ok, path}
    end
  end

  @doc """
  Returns whether Docker is installed and usable.

  This is a boolean convenience wrapper around `check/0`.

  Returns `true` only when all of the following conditions are satisfied:

    * the `docker` executable is found in `PATH`
    * the Docker client version can be queried
    * the Docker server version can be queried, which implies that the Docker
      daemon is reachable by the current process

  Returns `false` for all error cases, including a missing executable, a failed
  Docker client command, or an unreachable Docker daemon.

  Use `check/0` instead when the caller needs diagnostic details.
  """
  @spec available?() :: boolean()
  def available?() do
    match?({:ok, _}, check())
  end

  @doc """
  Checks whether Docker is installed and usable.

  This function performs the full Docker probe. It first locates the Docker
  executable with `executable/0`, then runs Docker version commands to obtain
  both the client and server versions.

  Returns `{:ok, info}` when Docker is usable. The returned map contains:

    * `:executable` - the resolved path to the Docker executable
    * `:client_version` - the Docker client version reported by the executable
    * `:server_version` - the Docker server version reported by the daemon

  Returns one of the following error tuples:

    * `{:error, :docker_not_found}` when the `docker` executable cannot be found
      in `PATH`
    * `{:error, {:docker_command_failed, status, output}}` when a Docker client
      command fails before daemon availability is established
    * `{:error, {:docker_unavailable, status, output}}` when the Docker server
      version cannot be queried, typically because the Docker daemon is stopped,
      unreachable, or inaccessible to the current user

  `status` is the command exit status and `output` is the trimmed combined
  standard output and standard error from the Docker command.
  """
  @spec check() :: check_result()
  def check() do
    with {:ok, docker} <- executable(),
         {:ok, client_version} <- docker_version(docker, "Client.Version"),
         {:ok, server_version} <- docker_version(docker, "Server.Version") do
      {:ok,
       %{
         executable: docker,
         client_version: client_version,
         server_version: server_version
       }}
    end
  end

  defp docker_version(docker, field) do
    args = ["version", "--format", "{{." <> field <> "}}"]

    case System.cmd(docker, args, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, status} when field == "Server.Version" ->
        {:error, {:docker_unavailable, status, String.trim(output)}}

      {output, status} ->
        {:error, {:docker_command_failed, status, String.trim(output)}}
    end
  rescue
    e in ErlangError ->
      {:error, {:docker_command_failed, 127, Exception.message(e)}}
  end
end
