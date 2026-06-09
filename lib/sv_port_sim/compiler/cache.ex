defmodule SvPortSim.Compiler.Cache do
  @moduledoc false

  @cache_version 1
  @default_cache_dir Path.join(["_build", "sv_port_sim", "cache"])

  @type cache_context :: map()
  @type cache_runner :: (Path.t() | nil -> {:ok, map()} | {:error, term()})

  @spec fetch_or_run(cache_context(), keyword(), cache_runner()) ::
          {:ok, map()} | {:error, term()}
  def fetch_or_run(context, opts, runner) when is_map(context) and is_list(opts) do
    if Keyword.get(opts, :cache, false) do
      fetch_or_run_cached(context, opts, runner)
    else
      fetch_or_run_uncached(runner)
    end
  end

  defp fetch_or_run_cached(context, opts, runner) do
    entry = cache_entry(context, opts)

    case read_result(entry.result_file) do
      {:ok, result} -> {:ok, mark_cache_hit(result, entry)}
      :miss -> fetch_or_store_cache_miss(entry, runner)
    end
  end

  defp fetch_or_run_uncached(runner) do
    with {:ok, result} <- runner.(nil) do
      {:ok, Map.put_new(result, :cache_hit?, false)}
    end
  end

  defp fetch_or_store_cache_miss(entry, runner) do
    with :ok <- mkdir_p(entry.entry_dir),
         {:ok, result} <- runner.(entry.entry_dir),
         result = mark_cache_miss(result, entry),
         :ok <- write_result(entry.result_file, result) do
      {:ok, result}
    end
  end

  defp cache_entry(context, opts) do
    cache_dir =
      opts
      |> Keyword.get(:cache_dir, @default_cache_dir)
      |> Path.expand()

    key = cache_key(context)
    entry_dir = Path.join(cache_dir, key)

    %{
      cache_key: key,
      entry_dir: entry_dir,
      result_file: Path.join(entry_dir, "result.term")
    }
  end

  defp mark_cache_hit(result, entry) do
    result
    |> Map.put(:cache_hit?, true)
    |> Map.put(:cache_key, entry.cache_key)
    |> Map.put(:cache_dir, entry.entry_dir)
  end

  defp mark_cache_miss(result, entry) do
    result
    |> Map.put(:cache_hit?, false)
    |> Map.put(:cache_key, entry.cache_key)
    |> Map.put(:cache_dir, entry.entry_dir)
  end

  defp cache_key(context) do
    context
    |> normalize_context()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalize_context(context) do
    %{
      cache_version: @cache_version,
      sv_port_sim_version: sv_port_sim_version(),
      backend: Map.fetch!(context, :backend),
      top_module: Map.fetch!(context, :top_module),
      mode: Map.fetch!(context, :mode),
      sources: normalize_sources(Map.fetch!(context, :sources)),
      wrapper_sha256: file_sha256(Map.fetch!(context, :wrapper_file)),
      docker_opts: Map.get(context, :docker_opts, [])
    }
  end

  defp normalize_sources(sources) do
    sources
    |> Enum.map(fn {module_name, source} -> {module_name, source} end)
    |> Enum.sort_by(fn {module_name, _source} -> module_name end)
  end

  defp sv_port_sim_version() do
    case Application.spec(:sv_port_sim, :vsn) do
      nil -> "unknown"
      version -> List.to_string(version)
    end
  end

  defp file_sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp read_result(path) do
    case File.read(path) do
      {:ok, binary} -> safe_binary_to_term(binary)
      {:error, _reason} -> :miss
    end
  end

  defp safe_binary_to_term(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    _ -> :miss
  end

  defp write_result(path, result) do
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, :erlang.term_to_binary(result)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} -> {:error, {:cache_write_failed, path, reason}}
    end
  end

  defp mkdir_p(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:cache_mkdir_failed, path, reason}}
    end
  end
end
