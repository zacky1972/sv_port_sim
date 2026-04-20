defmodule SvPortSim.Docker do
  @moduledoc """
  Utilities for detecting whether Docker is available on the host system.
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
  Returns the path to the Docker executable if it is available in PATH.
  """
  @spec executable() :: {:ok, Path.t()} | {:error, :docker_not_found}
  def executable() do
    case System.find_executable("docker") do
      nil -> {:error, :docker_not_found}
      path -> {:ok, path}
    end
  end

  @doc """
  Returns true if Docker executable exists and the Docker daemon is reachable.
  """
  @spec available?() :: boolean()
  def available?() do
    match?({:ok, _}, check())
  end

  @doc """
  Checks whether Docker is installed and usable.

  This checks both the Docker client executable and daemon connectivity.
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
