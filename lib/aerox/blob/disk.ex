defmodule Aerox.Blob.Disk do
  @moduledoc """
  The v1 blob adapter: one directory on local disk (DESIGN §4.4).

  ## Layout

  Three roots under `opts[:root]`:

      <root>/blobs/<did-safe>/<cid>        permanent objects
      <root>/tmp/<did-safe>/<key>          two-phase-write temp objects (not durable)
      <root>/quarantine/<did-safe>/<cid>   taken-down objects

  `<did-safe>` is the DID with every `:` replaced by `_` (`did:plc:abc` →
  `did_plc_abc`), which keeps the name portable to filesystems that reject
  colons; nothing else in a valid DID needs escaping. `<cid>` is the CID's
  base32 string form. Temp keys are 16 random bytes, hex-encoded.

  All three roots are on the same filesystem, so every commit — `make_permanent`,
  `put_permanent`, `quarantine`, `unquarantine` — is a single `File.rename/2`
  and therefore atomic: a reader never sees a half-written permanent object.
  Directories are created on demand with mode `0700`. The whole store is one
  directory; backing it up means copying that directory with its ownership bits.

  `presigned_url/4` is `:unsupported`; the PDS streams blobs itself.
  """

  @behaviour Aerox.Blob.Store

  alias Aerox.ATProto.CID

  @chunk 65_536
  @dir_mode 0o700

  @impl true
  def put_temp(did, body, opts) do
    key = random_key()
    path = temp_path(opts, did, key)

    with :ok <- ensure_dir(Path.dirname(path)),
         :ok <- write_body(path, body) do
      {:ok, key}
    end
  end

  @impl true
  def make_permanent(did, key, cid, opts) do
    temp = temp_path(opts, did, key)
    dest = blob_path(opts, did, cid)

    cond do
      File.regular?(dest) ->
        # Already committed (a retry, or the same bytes uploaded twice): the temp
        # object is redundant.
        rm_ignoring_missing(temp)

      not File.regular?(temp) ->
        {:error, :not_found}

      true ->
        with :ok <- ensure_dir(Path.dirname(dest)), do: File.rename(temp, dest)
    end
  end

  @impl true
  def put_permanent(did, cid, body, opts) do
    dest = blob_path(opts, did, cid)

    if File.regular?(dest) do
      :ok
    else
      # Write to temp, then rename: the permanent object appears atomically.
      with {:ok, key} <- put_temp(did, body, opts), do: commit_temp(did, key, cid, opts)
    end
  end

  defp commit_temp(did, key, cid, opts) do
    case make_permanent(did, key, cid, opts) do
      :ok ->
        :ok

      {:error, _} = error ->
        rm_ignoring_missing(temp_path(opts, did, key))
        error
    end
  end

  @impl true
  def has_temp?(did, key, opts), do: File.regular?(temp_path(opts, did, key))

  @impl true
  def has_stored?(did, cid, opts), do: File.regular?(blob_path(opts, did, cid))

  @impl true
  def get(did, cid, opts) do
    case File.read(blob_path(opts, did, cid)) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :enoent} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @impl true
  def stream(did, cid, opts) do
    path = blob_path(opts, did, cid)

    if File.regular?(path) do
      {:ok, File.stream!(path, @chunk)}
    else
      {:error, :not_found}
    end
  end

  @impl true
  def quarantine(did, cid, opts),
    do: move(blob_path(opts, did, cid), quarantine_path(opts, did, cid))

  @impl true
  def unquarantine(did, cid, opts),
    do: move(quarantine_path(opts, did, cid), blob_path(opts, did, cid))

  @impl true
  def delete(did, cid, opts), do: rm_ignoring_missing(blob_path(opts, did, cid))

  @impl true
  def delete_many(did, cids, opts) do
    Enum.reduce_while(cids, :ok, fn cid, :ok ->
      case delete(did, cid, opts) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @impl true
  def delete_all(did, opts) do
    Enum.reduce_while(["blobs", "tmp", "quarantine"], :ok, fn root, :ok ->
      case File.rm_rf(did_dir(opts, root, did)) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason, _} -> {:halt, {:error, reason}}
      end
    end)
  end

  @impl true
  def list(did, _list_opts, opts) do
    dir = did_dir(opts, "blobs", did)

    Stream.resource(
      fn ->
        case File.ls(dir) do
          {:ok, names} -> names
          {:error, :enoent} -> []
          {:error, reason} -> raise File.Error, reason: reason, action: "list", path: dir
        end
      end,
      fn
        [] -> {:halt, []}
        names -> {names, []}
      end,
      fn _ -> :ok end
    )
    |> Stream.flat_map(fn name ->
      case CID.parse(name) do
        {:ok, cid} -> [cid]
        # Not one of ours (an editor backup, a stray file): the reaper ignores it.
        {:error, _} -> []
      end
    end)
  end

  @impl true
  def presigned_url(_did, _cid, _ttl, _opts), do: :unsupported

  # -- paths -----------------------------------------------------------------

  @doc "The permanent path of `cid` for `did` — exposed for layout tests and backup tooling."
  @spec blob_path(keyword, String.t(), CID.t()) :: Path.t()
  def blob_path(opts, did, cid), do: Path.join(did_dir(opts, "blobs", did), CID.to_string(cid))

  defp temp_path(opts, did, key), do: Path.join(did_dir(opts, "tmp", did), key)

  defp quarantine_path(opts, did, cid),
    do: Path.join(did_dir(opts, "quarantine", did), CID.to_string(cid))

  defp did_dir(opts, root, did), do: Path.join([root!(opts), root, safe_did(did)])

  defp root!(opts) do
    Keyword.get(opts, :root) ||
      raise ArgumentError, "Aerox.Blob.Disk needs a :root option (got #{inspect(opts)})"
  end

  @doc "The filesystem-safe form of a DID: `:` → `_`."
  @spec safe_did(String.t()) :: String.t()
  def safe_did(did) when is_binary(did) do
    safe = String.replace(did, ":", "_")

    if safe == "" or safe in [".", ".."] or String.contains?(safe, ["/", "\\"]) do
      raise ArgumentError, "DID #{inspect(did)} is not a valid path component"
    end

    safe
  end

  # -- filesystem helpers ----------------------------------------------------

  defp random_key, do: 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp ensure_dir(dir) do
    if File.dir?(dir) do
      :ok
    else
      with :ok <- File.mkdir_p(dir) do
        # mkdir_p honours the umask; tighten our own directories regardless.
        File.chmod(dir, @dir_mode)
      end
    end
  end

  # Binaries and iolists are iodata; anything else is an Enumerable of chunks.
  defp write_body(path, body) when is_binary(body) or is_list(body), do: File.write(path, body)

  defp write_body(path, body) do
    body
    |> Stream.into(File.stream!(path))
    |> Stream.run()

    :ok
  rescue
    e in File.Error -> {:error, e.reason}
  end

  defp move(from, to) do
    if File.regular?(from) do
      with :ok <- ensure_dir(Path.dirname(to)), do: File.rename(from, to)
    else
      {:error, :not_found}
    end
  end

  defp rm_ignoring_missing(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _} = error -> error
    end
  end
end
