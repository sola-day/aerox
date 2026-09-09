defmodule Aerox.ImageServer do
  @moduledoc """
  Band 3: the image CDN, inside the AppView process but its own tree (DESIGN §16).

  `get/4` serves a preset of a blob from the disk cache, else fetches the
  original from the owner's PDS (`Aerox.ImageServer.Origin`), processes it
  (`Aerox.ImageServer.Processor`) and caches the result
  (`Aerox.ImageServer.Cache`). Concurrent misses for one key are collapsed
  (single-flight through `Aerox.ImageServer.Registry`).

  Supervision: add `Aerox.ImageServer` to the AppView's children; its
  supervisor starts the registry, the processing semaphore and (unless
  `sweeper: false`) the cache sweeper.

  Config, under `config :aerox, Aerox.ImageServer`: `cache_dir`, `max_bytes`,
  `sweep_interval`, `sweeper`, `max_source_bytes`, `max_pixels`, `quality`,
  `concurrency`, `origin` (module, for tests). Under
  `config :aerox, Aerox.ImageServer.Origin`: `identity_cache`, `http`, `timeout`.
  """
  use Boundary, top_level?: true, deps: [Aerox.ATProto, Aerox.Identity], exports: :all

  alias Aerox.ATProto.{CID, Syntax}
  alias Aerox.ImageServer.{Cache, Presets, Processor, Semaphore}

  @registry Aerox.ImageServer.Registry
  @flight_timeout 30_000

  @type error ::
          :bad_path | :bad_preset | :bad_format | :not_found | :not_an_image | :upstream | :busy
  @type source :: :hit | :miss

  # ------------------------------------------------------------ supervision

  @doc "The children the image server needs, for a supervisor."
  @spec children() :: [Supervisor.child_spec() | {module, term} | module]
  def children do
    [
      {Registry, keys: :unique, name: @registry},
      {Semaphore, limit: config(:concurrency, 4)}
    ] ++ if config(:sweeper, true), do: [Cache.Sweeper], else: []
  end

  @doc "A supervisor child spec wrapping `children/0` (`Aerox.ImageServer.Supervisor`)."
  def child_spec(_opts) do
    %{
      id: Aerox.ImageServer.Supervisor,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [children(), [strategy: :one_for_one, name: Aerox.ImageServer.Supervisor]]}
    }
  end

  # ------------------------------------------------------------ serving

  @doc """
  The processed image for `preset`/`did`/`cid` in `format`: `{:ok, path,
  content_type}` where `path` is the cached file. Errors map to HTTP in
  `AeroxWeb.Image.Plug`: `:bad_path`/`:bad_preset`/`:bad_format`/
  `:not_an_image` → 400, `:not_found` → 404, `:busy` → 503, `:upstream` → 502.
  """
  @spec get(String.t(), String.t(), String.t(), Presets.format() | String.t()) ::
          {:ok, String.t(), String.t()} | {:error, error}
  def get(preset, did, cid, format) do
    with {:ok, format} <- normalize_format(format),
         {:ok, options} <- Presets.parse_path(Presets.path(preset, did, cid)),
         :ok <- validate(did, cid),
         {:ok, path, content_type, _source} <- serve(%{options | format: format}) do
      {:ok, path, content_type}
    end
  end

  @doc "`get/4` from a request path relative to the `/img` mount; also says whether the cache had it."
  @spec get_path(String.t()) :: {:ok, String.t(), String.t(), source} | {:error, error}
  def get_path(path) do
    with {:ok, options} <- Presets.parse_path(path),
         :ok <- validate(options.did, options.cid) do
      serve(options)
    end
  end

  @doc "Removes every cached rendition of a blob (takedowns, DESIGN §17.2)."
  defdelegate purge(did, cid), to: Cache

  defp normalize_format(f) when f in [:jpeg, :webp], do: {:ok, f}

  defp normalize_format(f) when is_binary(f) do
    case Presets.parse_format(f) do
      {:ok, format} -> {:ok, format}
      :error -> {:error, :bad_format}
    end
  end

  defp normalize_format(_), do: {:error, :bad_format}

  # upstream: invalid DID or CID → 400
  defp validate(did, cid) do
    if Syntax.valid_did?(did) and CID.valid?(cid), do: :ok, else: {:error, :bad_path}
  end

  defp serve(%{preset: preset, did: did, cid: cid, format: format} = options) do
    case Cache.fetch(preset, did, cid, format) do
      {:ok, path} ->
        {:ok, path, Presets.content_type(format), :hit}

      :miss ->
        with {:ok, path, content_type} <-
               single_flight({preset, did, cid, format}, fn -> fill(options) end) do
          {:ok, path, content_type, :miss}
        end
    end
  end

  defp fill(%{preset: preset, did: did, cid: cid, format: format} = options) do
    with {:ok, source, _content_type} <- origin().fetch(did, cid),
         {:ok, bytes} <- process(source, options),
         {:ok, path} <- store(preset, did, cid, format, bytes) do
      {:ok, path, Presets.content_type(format)}
    end
  end

  defp process(source, options) do
    case Processor.process(source, Map.take(options, [:width, :height, :fit, :min, :format])) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :busy} -> {:error, :busy}
      # undecodable or over the bomb limits: the origin served something the
      # CDN cannot turn into an image (upstream: 502 from a sharp failure)
      {:error, _} -> {:error, :upstream}
    end
  end

  defp store(preset, did, cid, format, bytes) do
    case Cache.put(preset, did, cid, format, bytes) do
      {:ok, path} -> {:ok, path}
      {:error, _} -> {:error, :upstream}
    end
  end

  # One fill per key: the first caller registers and does the work; later
  # callers wait for it to exit, then take the cache hit it left behind.
  defp single_flight(key, fun, attempts \\ 0) do
    case Registry.register(@registry, key, nil) do
      {:ok, _} ->
        try do
          fun.()
        after
          Registry.unregister(@registry, key)
        end

      {:error, {:already_registered, pid}} ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          @flight_timeout ->
            Process.demonitor(ref, [:flush])
            :ok
        end

        {preset, did, cid, format} = key

        case Cache.fetch(preset, did, cid, format) do
          {:ok, path} -> {:ok, path, Presets.content_type(format)}
          :miss when attempts < 3 -> single_flight(key, fun, attempts + 1)
          :miss -> fun.()
        end
    end
  end

  defp origin, do: config(:origin, Aerox.ImageServer.Origin)

  defp config(key, default),
    do: Keyword.get(Application.get_env(:aerox, __MODULE__, []), key, default)
end
