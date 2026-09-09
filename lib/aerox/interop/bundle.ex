defmodule Aerox.Interop.Bundle do
  @moduledoc """
  The portable account bundle, format version 1 (DESIGN §13.0; the byte-level
  description is `docs/BUNDLE.md`). One directory per account:

      manifest.json   always plaintext: version, identity, counts, hashes,
                      the encryption envelope, and a JWS over all of it
      account.json    email, scrypt hashes, app passwords, invites, prefs
      signing.key     raw 32-byte secp256k1 private key
      repo.car        the repo as `com.atproto.sync.getRepo` returns it
      state.json      per-record / per-blob / per-block state the CAR lacks
      blobs/<cid>     blob bytes; quarantine/<cid> for taken-down blobs
      seq.car         optional: the account's `repo_seq` rows, one DAG-CBOR
                      block each, for cursor continuity on takeover

  Every file but the manifest is encrypted unless the bundle was written
  with `insecure_plaintext: true` (`Aerox.Interop.Bundle.Crypto`). Readers
  refuse an unknown major `bundle_version` and ignore files they do not
  know. The manifest's readable fields are informational: the authoritative
  manifest is the JWS payload, so any edit to the file is either detected
  (payload tampered → bad signature) or irrelevant.
  """

  alias Aerox.ATProto.{CAR, CID, DagCBOR}
  alias Aerox.Interop.Bundle.Crypto

  @version 1
  @known_files ~w(account.json signing.key repo.car state.json seq.car)

  defstruct dir: nil, manifest: nil, content_key: nil, signer: nil

  @type t :: %__MODULE__{
          dir: Path.t(),
          manifest: map,
          content_key: <<_::256>> | nil,
          signer: String.t() | nil
        }

  @typedoc "A file body: a binary, or an enumerable of binaries."
  @type body :: binary | Enumerable.t()

  @typedoc """
  What `write/3` needs. `blobs` and `quarantine` map CID strings to bodies;
  `seq` is `{body, event_count}` or nil; `counts` gives records and blocks.
  """
  @type contents :: %{
          required(:did) => String.t(),
          required(:handle) => String.t() | nil,
          required(:source) => map,
          required(:account) => map,
          required(:signing_key) => <<_::256>>,
          required(:repo_car) => body,
          required(:state) => map,
          required(:counts) => %{records: non_neg_integer, blocks: non_neg_integer},
          optional(:blobs) => [{String.t(), body}],
          optional(:quarantine) => [{String.t(), body}],
          optional(:seq) => {body, non_neg_integer} | nil
        }

  def version, do: @version

  # ---------------------------------------------------------------- write

  @doc """
  Writes a bundle into `dir` (created; must be empty or absent).

  Options: `recipients:` (`Aerox.Interop.Bundle.Crypto.recipient/0` list),
  `insecure_plaintext:` (required when there are no recipients),
  `signer:` (default `Aerox.PDS.Config.signer/0`), `chunk_size:`.
  """
  @spec write(Path.t(), contents, keyword) :: {:ok, map} | {:error, term}
  def write(dir, contents, opts \\ []) do
    recipients = Keyword.get(opts, :recipients, [])
    plaintext? = Keyword.get(opts, :insecure_plaintext, false)

    cond do
      recipients == [] and not plaintext? ->
        {:error, :refusing_plaintext_bundle}

      File.exists?(dir) and File.ls!(dir) != [] ->
        {:error, {:directory_not_empty, dir}}

      true ->
        File.mkdir_p!(dir)
        key = if recipients == [], do: nil, else: Crypto.generate_content_key()
        chunk_size = Keyword.get(opts, :chunk_size, Crypto.default_chunk_size())
        signer = Keyword.get_lazy(opts, :signer, &Aerox.PDS.Config.signer/0)

        try do
          do_write(dir, contents, key, chunk_size, recipients, signer)
        rescue
          e in [ArgumentError, File.Error, Crypto.Error] ->
            {:error, {:write_failed, Exception.message(e)}}
        end
    end
  end

  defp do_write(dir, c, key, chunk_size, recipients, signer) do
    w = fn rel, body -> write_file(dir, rel, body, key, chunk_size) end
    account_json = Jason.encode!(c.account, pretty: true)
    state_json = Jason.encode!(c.state, pretty: true)

    {account_sha, _} = w.("account.json", account_json)
    {state_sha, _} = w.("state.json", state_json)
    {_, 32} = w.("signing.key", c.signing_key)
    {car_sha, car_size} = w.("repo.car", c.repo_car)

    blobs = write_blobs(w, "blobs", Map.get(c, :blobs, []))
    quarantine = write_blobs(w, "quarantine", Map.get(c, :quarantine, []))

    {seq_sha, seq_count} =
      case Map.get(c, :seq) do
        nil -> {nil, 0}
        {body, n} -> {elem(w.("seq.car", body), 0), n}
      end

    manifest = %{
      "bundle_version" => @version,
      "did" => c.did,
      "handle" => c.handle,
      "source" => c.source,
      "created_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "counts" => %{
        "records" => c.counts.records,
        "blocks" => c.counts.blocks,
        "blobs" => length(blobs),
        "quarantine" => length(quarantine),
        "seq_events" => seq_count
      },
      "hashes" => %{
        "repo_car" => car_sha,
        "account_json" => account_sha,
        "state_json" => state_sha,
        "seq_car" => seq_sha,
        "blobs" => blobs,
        "quarantine" => quarantine
      },
      "sizes" => %{"repo_car" => car_size},
      "encryption" =>
        if key do
          %{
            "scheme" => "aerox-bundle-v1",
            "cipher" => "AES-256-GCM",
            "chunk_size" => chunk_size,
            "recipients" => Crypto.wrap_key(key, recipients)
          }
        end
    }

    payload = Jason.encode!(manifest)

    with {:ok, jws} <- Crypto.sign(payload, signer) do
      signed =
        Map.put(manifest, "signature", %{
          "jws" => jws,
          "kid" => Aerox.Crypto.Signer.did_key(signer)
        })

      File.write!(Path.join(dir, "manifest.json"), Jason.encode!(signed, pretty: true) <> "\n")
      {:ok, signed}
    end
  end

  defp write_blobs(w, sub, entries) do
    Enum.map(entries, fn {cid_str, body} ->
      cid = CID.parse!(cid_str)
      {sha, _} = w.(Path.join(sub, cid_str), body)

      if Base.encode16(cid.digest, case: :lower) != sha,
        do: raise(ArgumentError, "blob #{cid_str}: bytes do not hash to the CID")

      cid_str
    end)
  end

  # Streams the body to disk (encrypting when keyed) while hashing the plaintext.
  defp write_file(dir, rel, body, key, chunk_size) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    chunks = if is_binary(body), do: [body], else: Stream.map(body, &IO.iodata_to_binary/1)
    hasher = :crypto.hash_init(:sha256)

    {chunks, acc} =
      Enum.map_reduce(chunks, {hasher, 0}, fn chunk, {h, n} ->
        {chunk, {:crypto.hash_update(h, chunk), n + byte_size(chunk)}}
      end)

    # map_reduce is eager over the input, so the hash is final before the write;
    # the write itself still streams through the encryptor.
    out = if key, do: Crypto.encrypt_stream(key, rel, chunks, chunk_size), else: chunks
    out |> Stream.map(&IO.iodata_to_binary/1) |> Stream.into(File.stream!(path)) |> Stream.run()
    {digest, size} = acc
    {Base.encode16(:crypto.hash_final(digest), case: :lower), size}
  end

  # ----------------------------------------------------------------- read

  @doc """
  Opens a bundle: parses and verifies the manifest signature, checks the
  major version, and unwraps the content key when encrypted. Nothing else
  is read yet. Options: `secret:` (`{:jwk, private}` or `{:passphrase, p}`),
  `expect_signer:` (a `did:key` the manifest must be signed by).
  """
  @spec read(Path.t(), keyword) :: {:ok, t} | {:error, term}
  def read(dir, opts \\ []) do
    with {:ok, raw} <- read_manifest_file(dir),
         {:ok, %{"signature" => %{"jws" => jws}}} <- {:ok, raw},
         {:ok, payload, signer} <- Crypto.verify(jws),
         :ok <- check_signer(signer, opts[:expect_signer]),
         {:ok, manifest} <- Jason.decode(payload),
         :ok <- check_version(manifest),
         {:ok, key} <- unwrap(manifest, opts[:secret]) do
      {:ok, %__MODULE__{dir: dir, manifest: manifest, content_key: key, signer: signer}}
    else
      {:ok, %{}} -> {:error, :unsigned_manifest}
      {:error, _} = e -> e
    end
  end

  defp read_manifest_file(dir) do
    with {:ok, text} <- File.read(Path.join(dir, "manifest.json")),
         {:ok, %{} = raw} <- Jason.decode(text) do
      {:ok, raw}
    else
      {:ok, _} -> {:error, :malformed_manifest}
      {:error, :enoent} -> {:error, {:no_manifest, dir}}
      {:error, %Jason.DecodeError{}} -> {:error, :malformed_manifest}
      {:error, _} = e -> e
    end
  end

  defp check_signer(_signer, nil), do: :ok
  defp check_signer(signer, signer), do: :ok
  defp check_signer(signer, _expected), do: {:error, {:unexpected_signer, signer}}

  defp check_version(%{"bundle_version" => @version}), do: :ok

  defp check_version(%{"bundle_version" => v}) when is_integer(v),
    do: {:error, {:unsupported_bundle_version, v}}

  defp check_version(_), do: {:error, :missing_bundle_version}

  defp unwrap(%{"encryption" => nil}, _secret), do: {:ok, nil}

  defp unwrap(
         %{"encryption" => %{"scheme" => "aerox-bundle-v1", "recipients" => entries}},
         secret
       ) do
    case secret do
      nil ->
        {:error, :bundle_is_encrypted}

      secret ->
        case Crypto.unwrap_key(entries, secret) do
          {:ok, key} -> {:ok, key}
          :error -> {:error, :cannot_unwrap_content_key}
        end
    end
  end

  defp unwrap(%{"encryption" => other}, _), do: {:error, {:unsupported_encryption, other}}
  defp unwrap(_, _), do: {:error, :malformed_manifest}

  @doc "Is the bundle encrypted?"
  def encrypted?(%__MODULE__{manifest: %{"encryption" => e}}), do: e != nil

  @doc "The plaintext of a bundle file as a lazy stream of binaries."
  @spec stream(t, String.t()) :: {:ok, Enumerable.t()} | {:error, :not_found}
  def stream(%__MODULE__{} = b, rel) do
    path = Path.join(b.dir, rel)

    if File.regular?(path) do
      raw = File.stream!(path, 65_536)
      {:ok, if(b.content_key, do: Crypto.decrypt_stream(b.content_key, rel, raw), else: raw)}
    else
      {:error, :not_found}
    end
  end

  @doc "The plaintext of a bundle file as one binary."
  @spec read_file(t, String.t()) :: {:ok, binary} | {:error, term}
  def read_file(b, rel) do
    with {:ok, s} <- stream(b, rel) do
      {:ok, s |> Enum.to_list() |> IO.iodata_to_binary()}
    end
  rescue
    e in Crypto.Error -> {:error, {:decrypt_failed, rel, e.reason}}
  end

  @doc "sha256 (hex) and size of a bundle file's plaintext, streaming."
  @spec hash_file(t, String.t()) :: {:ok, String.t(), non_neg_integer} | {:error, term}
  def hash_file(b, rel) do
    with {:ok, s} <- stream(b, rel) do
      {h, n} =
        Enum.reduce(s, {:crypto.hash_init(:sha256), 0}, fn c, {h, n} ->
          {:crypto.hash_update(h, c), n + byte_size(c)}
        end)

      {:ok, Base.encode16(:crypto.hash_final(h), case: :lower), n}
    end
  rescue
    e in Crypto.Error -> {:error, {:decrypt_failed, rel, e.reason}}
  end

  @doc """
  DESIGN §13.0 rule 5: recomputes every hash in the manifest from the files
  — `repo.car`, `account.json`, `state.json`, `seq.car`, every blob against
  its CID — before anything touches a database. Returns the list of
  problems, empty when the bundle is intact.
  """
  @spec verify_hashes(t) :: :ok | {:error, [term]}
  def verify_hashes(%__MODULE__{manifest: m} = b) do
    hashes = m["hashes"] || %{}

    file_problems =
      for {rel, key} <- [
            {"repo.car", "repo_car"},
            {"account.json", "account_json"},
            {"state.json", "state_json"},
            {"seq.car", "seq_car"}
          ],
          problem = check_hash(b, rel, hashes[key]),
          problem != nil,
          do: problem

    blob_problems =
      for sub <- ["blobs", "quarantine"],
          cid_str <- hashes[sub] || [],
          do: check_blob(b, sub, cid_str)

    key_problem =
      case read_file(b, "signing.key") do
        {:ok, <<_::binary-size(32)>>} -> []
        {:ok, _} -> [{:signing_key, :not_32_bytes}]
        {:error, reason} -> [{:signing_key, reason}]
      end

    case file_problems ++ List.flatten(blob_problems) ++ key_problem do
      [] -> :ok
      problems -> {:error, problems}
    end
  end

  defp check_hash(_b, "seq.car", nil), do: nil

  defp check_hash(b, rel, expected) do
    case {hash_file(b, rel), expected} do
      {{:ok, ^expected, _}, _} -> nil
      {{:ok, actual, _}, _} -> {:hash_mismatch, rel, expected, actual}
      {{:error, reason}, _} -> {:unreadable, rel, reason}
    end
  end

  defp check_blob(b, sub, cid_str) do
    rel = Path.join(sub, cid_str)

    with {:ok, cid} <- CID.parse(cid_str),
         {:ok, actual, _} <- hash_file(b, rel) do
      if Base.encode16(cid.digest, case: :lower) == actual, do: [], else: [{:hash_mismatch, rel}]
    else
      {:error, reason} -> [{:unreadable, rel, reason}]
    end
  end

  @doc "Parses `seq.car` into the rows it carries (`seq`, `did`, `event_type`, `event`, `invalidated`, `sequenced_at`), ascending by seq."
  @spec seq_rows(t) :: {:ok, [map]} | {:error, term}
  def seq_rows(b) do
    case read_file(b, "seq.car") do
      {:error, :not_found} ->
        {:ok, []}

      {:error, _} = e ->
        e

      {:ok, car} ->
        with {:ok, %{blocks: blocks}} <- CAR.decode(car) do
          rows =
            for {_cid, bytes} <- blocks do
              body = DagCBOR.decode!(bytes)
              {:ok, at, _} = DateTime.from_iso8601(body["sequencedAt"])

              %{
                seq: body["seq"],
                did: body["did"],
                event_type: body["eventType"],
                event: body["event"].data,
                invalidated: body["invalidated"] || false,
                sequenced_at: %{at | microsecond: {elem(at.microsecond, 0), 6}}
              }
            end

          {:ok, Enum.sort_by(rows, & &1.seq)}
        end
    end
  end

  @doc "Encodes `repo_seq`-shaped rows as `seq.car` (a rootless CAR, one DAG-CBOR block per event)."
  @spec encode_seq([map]) :: binary
  def encode_seq(rows) do
    blocks =
      Enum.map(rows, fn r ->
        bytes =
          DagCBOR.encode(%{
            "seq" => r.seq,
            "did" => r.did,
            "eventType" => r.event_type,
            "event" => Aerox.ATProto.Bytes.new(r.event),
            "invalidated" => r.invalidated || false,
            "sequencedAt" => DateTime.to_iso8601(r.sequenced_at)
          })

        {CID.for_cbor(bytes), bytes}
      end)

    CAR.encode(nil, blocks)
  end

  @doc "Bundle directories under `dir`: `dir` itself when it holds a manifest, else every child that does."
  @spec discover(Path.t()) :: [Path.t()]
  def discover(dir) do
    cond do
      File.regular?(Path.join(dir, "manifest.json")) ->
        [dir]

      File.dir?(dir) ->
        dir
        |> File.ls!()
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&File.regular?(Path.join(&1, "manifest.json")))

      true ->
        []
    end
  end

  @doc "Files the format knows about (for tests documenting 'unknown files are tolerated')."
  def known_files, do: @known_files
end
