defmodule Aerox.ImageServer.Cache do
  @moduledoc """
  Processed outputs on local disk (DESIGN §16), laid out as
  `<cache>/<preset>/<did>/<cid>.<fmt>` under the configured directory, bounded
  by `max_bytes` (default 1 GB). A hit touches the file's mtime, so the
  sweeper (`Aerox.ImageServer.Cache.Sweeper`) evicts least-recently-served
  first. Writes are atomic (temp file + rename); an existing entry is never
  overwritten. `purge/2` removes every preset and format for one blob (used by
  takedowns, §17.2). Originals are never cached.

  Config, under `config :aerox, Aerox.ImageServer`: `cache_dir` (falls back
  to `Aerox.AppView.Config.image_cache_dir/0`'s key, `image_cache_dir` under
  `Aerox.AppView`), `max_bytes`, `sweep_interval` (ms), `sweeper` (boolean).
  """

  alias Aerox.ImageServer.Presets

  @default_max_bytes 1024 * 1024 * 1024

  @doc "The cache root directory."
  @spec dir() :: String.t()
  def dir do
    config(:cache_dir) ||
      Keyword.get(Application.get_env(:aerox, Aerox.AppView, []), :image_cache_dir) ||
      "tmp/image-cache"
  end

  @doc "The size bound in bytes."
  def max_bytes, do: config(:max_bytes) || @default_max_bytes

  @doc "The on-disk path for an entry (the DID and CID must be validated by the caller)."
  @spec path(String.t(), String.t(), String.t(), Presets.format()) :: String.t()
  def path(preset, did, cid, format),
    do: Path.join([dir(), preset, did, cid <> "." <> Presets.extension(format)])

  @doc "A hit returns the path and refreshes its mtime for the LRU; a miss is `:miss`."
  @spec fetch(String.t(), String.t(), String.t(), Presets.format()) ::
          {:ok, String.t()} | :miss
  def fetch(preset, did, cid, format) do
    file = path(preset, did, cid, format)

    case File.stat(file) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > 0 ->
        File.touch(file)
        {:ok, file}

      _ ->
        :miss
    end
  end

  @doc "Stores processed bytes; an existing entry wins (upstream's `wx` flag)."
  @spec put(String.t(), String.t(), String.t(), Presets.format(), binary) ::
          {:ok, String.t()} | {:error, term}
  def put(preset, did, cid, format, bytes) when is_binary(bytes) do
    file = path(preset, did, cid, format)
    tmp = file <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(tmp, bytes) do
      if File.exists?(file) do
        File.rm(tmp)
        {:ok, file}
      else
        case File.rename(tmp, file) do
          :ok ->
            {:ok, file}

          {:error, reason} ->
            File.rm(tmp)
            {:error, reason}
        end
      end
    end
  end

  @doc "Removes every preset/format entry for one blob. Returns the number of files removed."
  @spec purge(String.t(), String.t()) :: non_neg_integer
  def purge(did, cid) do
    for preset <- Presets.names(),
        format <- [:jpeg, :webp],
        file = path(preset, did, cid, format),
        File.rm(file) == :ok,
        reduce: 0 do
      n -> n + 1
    end
  end

  @doc "Removes everything (tests)."
  def clear, do: File.rm_rf(dir())

  @doc "Total bytes on disk."
  @spec size() :: non_neg_integer
  def size, do: entries() |> Enum.map(& &1.size) |> Enum.sum()

  @doc """
  Evicts least-recently-used entries until the cache is at or under
  `max_bytes` (leaving 10 % headroom so the sweeper is not re-triggered by the
  next write). Returns `{bytes_before, bytes_after, files_removed}`.
  """
  @spec sweep(non_neg_integer | nil) :: {non_neg_integer, non_neg_integer, non_neg_integer}
  def sweep(limit \\ nil) do
    limit = limit || max_bytes()
    entries = entries()
    total = entries |> Enum.map(& &1.size) |> Enum.sum()

    if total <= limit do
      {total, total, 0}
    else
      target = div(limit * 9, 10)

      {remaining, removed} =
        entries
        |> Enum.sort_by(& &1.mtime)
        |> Enum.reduce_while({total, 0}, fn entry, {bytes, n} ->
          if bytes <= target do
            {:halt, {bytes, n}}
          else
            case File.rm(entry.path) do
              :ok -> {:cont, {bytes - entry.size, n + 1}}
              _ -> {:cont, {bytes, n}}
            end
          end
        end)

      {total, remaining, removed}
    end
  end

  # Every regular file below the root, with size and mtime. Stale temp files
  # from a crashed write are included so they are eventually evicted too.
  defp entries do
    root = dir()

    if File.dir?(root) do
      root
      |> walk()
      |> Enum.flat_map(fn file ->
        case File.stat(file, time: :posix) do
          {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} ->
            [%{path: file, size: size, mtime: mtime}]

          _ ->
            []
        end
      end)
    else
      []
    end
  end

  defp walk(path) do
    case File.ls(path) do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          full = Path.join(path, name)
          if File.dir?(full), do: walk(full), else: [full]
        end)

      {:error, _} ->
        []
    end
  end

  defp config(key), do: Keyword.get(Application.get_env(:aerox, Aerox.ImageServer, []), key)

  defmodule Sweeper do
    @moduledoc "Runs `Aerox.ImageServer.Cache.sweep/0` every `sweep_interval` ms (default 10 min)."
    use GenServer
    require Logger

    @default_interval 600_000

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(opts) do
      interval =
        Keyword.get(
          opts,
          :interval,
          Keyword.get(Application.get_env(:aerox, Aerox.ImageServer, []), :sweep_interval) ||
            @default_interval
        )

      Process.send_after(self(), :sweep, interval)
      {:ok, %{interval: interval}}
    end

    @impl true
    def handle_info(:sweep, state) do
      case Aerox.ImageServer.Cache.sweep() do
        {before, after_bytes, n} when n > 0 ->
          Logger.info("image cache sweep: #{before} -> #{after_bytes} bytes, #{n} files evicted")

        _ ->
          :ok
      end

      Process.send_after(self(), :sweep, state.interval)
      {:noreply, state}
    end
  end
end
