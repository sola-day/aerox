defmodule Aerox.Interop.Bundle.Postgres do
  @moduledoc """
  The native adapter: `aerox_pds` ⇄ bundle (DESIGN §13.0, §13.2).

  **Export** writes one account: `repo.car` from `repo_block` through the
  kernel's CAR writer (commit, MST nodes, records — the `getRepo` order),
  `account.json` with everything Layer A loses, `signing.key`, `state.json`
  with per-record, per-blob and per-block state, blob bytes from the
  configured `Aerox.Blob.Store`, and `seq.car` with the account's `repo_seq`
  rows when `takeover: true`.

  **Import** is the one import path for every source. It verifies the bundle
  first (hashes, then the CAR through `Aerox.ATProto.Repo.verify_repo_car/2`
  with the DID and the bundled signing key, so the MST root is recomputed
  and the commit signature checked before any row is written), stores blob
  bytes, then writes every table of the account in one transaction:
  mutable rows `ON CONFLICT DO UPDATE`, blocks `ON CONFLICT DO NOTHING`,
  block bytes verbatim — nothing is re-signed. `repo_root`, `record`,
  `backlink` and `record_blob` are re-derived from the CAR; stale rows of the
  account that the bundle does not carry are deleted, so a re-run converges.
  Progress goes to `interop_progress` (`Aerox.Interop.Progress`).

  With `takeover: true` the `repo_seq` rows are inserted with their original
  `seq`. Run the import while the PDS is stopped (DESIGN §13.2 "runs on the
  target machine"): `Aerox.Sequencer` reads `max(seq)` only at start, and no
  events are emitted for imported accounts — downstream is migrated
  separately (§13.4 point 2).
  """
  import Ecto.Query
  alias Aerox.ATProto.{CAR, CID, Data, DagCBOR, Syntax}
  alias Aerox.ATProto.Repo, as: KRepo
  alias Aerox.Blob.Store
  alias Aerox.Interop.{Bundle, Progress}
  alias Aerox.PDS.{Blockstore, Records, Repo}

  alias Aerox.PDS.Schema.{
    Account,
    AccountPref,
    Actor,
    AppPassword,
    Backlink,
    Blob,
    InviteCode,
    InviteCodeUse,
    Record,
    RecordBlob,
    RepoBlock,
    RepoRoot,
    RepoSeq
  }

  require Logger

  @type report :: %{
          did: String.t(),
          records: non_neg_integer,
          blocks: non_neg_integer,
          blobs: non_neg_integer,
          seq_events: non_neg_integer,
          commit_cid: String.t(),
          rev: String.t()
        }

  # ================================================================ export

  @doc """
  Exports `did` into `dir`. Options: `takeover:` (include `seq.car`),
  `store:` (blob adapter, default configured), plus `Aerox.Interop.Bundle.write/3`'s
  `recipients:`, `insecure_plaintext:`, `signer:`.
  """
  @spec export(String.t(), Path.t(), keyword) :: {:ok, map} | {:error, term}
  def export(did, dir, opts \\ []) do
    with {:ok, contents} <- contents(did, opts) do
      Bundle.write(
        dir,
        contents,
        Keyword.take(opts, [:recipients, :insecure_plaintext, :signer, :chunk_size])
      )
    end
  end

  @doc "Everything `Aerox.Interop.Bundle.write/3` needs for `did`, read from `aerox_pds`."
  @spec contents(String.t(), keyword) :: {:ok, Bundle.contents()} | {:error, term}
  def contents(did, opts \\ []) do
    store = Keyword.get_lazy(opts, :store, &Store.adapter/0)

    with %Actor{} = actor <- Repo.get(Actor, did) || {:error, {:account_not_found, did}},
         %RepoRoot{} = root <- Repo.get(RepoRoot, did) || {:error, {:no_repo, did}},
         root_cid = CID.parse!(root.cid),
         {:ok, blocks} <- KRepo.full_repo_blocks(Blockstore.new(did), root_cid) do
      account = Repo.get(Account, did)
      records = Repo.all(from(r in Record, where: r.did == ^did, order_by: r.uri))
      blob_rows = Repo.all(from(b in Blob, where: b.did == ^did, order_by: b.cid))

      block_revs =
        from(b in RepoBlock, where: b.did == ^did, select: {b.cid, b.rev})
        |> Repo.all()
        |> Map.new()

      {stored, quarantined, missing} = blob_bodies(store, did, blob_rows)

      if missing != [],
        do:
          Logger.warning(
            "export #{did}: #{length(missing)} blob object(s) not in the store: #{inspect(missing)}"
          )

      seq =
        if Keyword.get(opts, :takeover, false) do
          rows = Repo.all(from(s in RepoSeq, where: s.did == ^did, order_by: s.seq))
          {Bundle.encode_seq(Enum.map(rows, &Map.from_struct/1)), length(rows)}
        end

      {:ok,
       %{
         did: did,
         handle: actor.handle,
         source: source(),
         account: account_json(actor, account, did),
         signing_key: actor.signing_key,
         repo_car: CAR.encode_stream(root_cid, blocks),
         state: %{
           "repo_root" => %{
             "cid" => root.cid,
             "rev" => root.rev,
             "indexed_at" => iso(root.indexed_at)
           },
           "records" =>
             Map.new(records, fn r ->
               {r.uri,
                %{
                  "cid" => r.cid,
                  "rev" => r.rev,
                  "indexed_at" => iso(r.indexed_at),
                  "takedown_ref" => r.takedown_ref
                }}
             end),
           "blobs" =>
             Map.new(blob_rows, fn b ->
               {b.cid,
                %{
                  "mime_type" => b.mime_type,
                  "size" => b.size,
                  "created_at" => iso(b.created_at),
                  "takedown_ref" => b.takedown_ref
                }}
             end),
           "blocks" =>
             Map.new(blocks, fn {cid, _} ->
               {CID.to_string(cid), block_revs[CID.to_string(cid)] || root.rev}
             end)
         },
         counts: %{records: length(records), blocks: length(blocks)},
         blobs: stored,
         quarantine: quarantined,
         seq: seq
       }}
    end
  end

  defp source do
    cfg = Aerox.Interop.config()

    %{
      "impl" => Keyword.get(cfg, :source_impl, "aerox"),
      "version" =>
        Keyword.get(cfg, :source_version, to_string(Application.spec(:aerox, :vsn) || "dev")),
      "host" => Aerox.PDS.Config.hostname()
    }
  end

  defp account_json(actor, account, did) do
    app_passwords = Repo.all(from(a in AppPassword, where: a.did == ^did, order_by: a.name))
    codes = Repo.all(from(i in InviteCode, where: i.for_account == ^did, order_by: i.code))
    code_strs = Enum.map(codes, & &1.code)

    uses =
      Repo.all(
        from(u in InviteCodeUse, where: u.code in ^code_strs, order_by: [u.code, u.used_at])
      )

    prefs = Repo.all(from(p in AccountPref, where: p.did == ^did, order_by: p.id))

    %{
      "did" => did,
      "handle" => actor.handle,
      "created_at" => iso(actor.created_at),
      "takedown_ref" => actor.takedown_ref,
      "deactivated_at" => iso(actor.deactivated_at),
      "delete_after" => iso(actor.delete_after),
      "email" => account && account.email,
      "email_confirmed_at" => iso(account && account.email_confirmed_at),
      "password_scrypt" => account && account.password_scrypt,
      "invites_disabled" => (account && account.invites_disabled) || false,
      "app_passwords" =>
        Enum.map(app_passwords, fn a ->
          %{
            "name" => a.name,
            "password_scrypt" => a.password_scrypt,
            "created_at" => iso(a.created_at),
            "privileged" => a.privileged
          }
        end),
      "invite_codes" =>
        Enum.map(codes, fn c ->
          %{
            "code" => c.code,
            "available_uses" => c.available_uses,
            "disabled" => c.disabled,
            "created_by" => c.created_by,
            "created_at" => iso(c.created_at),
            "uses" =>
              for(
                u <- uses,
                u.code == c.code,
                do: %{"used_by" => u.used_by, "used_at" => iso(u.used_at)}
              )
          }
        end),
      "preferences" => Enum.map(prefs, &%{"name" => &1.name, "value" => &1.value})
    }
  end

  # {stored, quarantined, missing}: bodies are lazy streams, read only when the bundle is written.
  defp blob_bodies(store, did, rows) do
    Enum.reduce(rows, {[], [], []}, fn row, {stored, quarantined, missing} ->
      cid = CID.parse!(row.cid)

      cond do
        row.temp_key != nil ->
          {stored, quarantined, missing}

        row.takedown_ref != nil ->
          case quarantined_stream(store, did, cid) do
            {:ok, body} -> {stored, [{row.cid, body} | quarantined], missing}
            :error -> {stored, quarantined, [row.cid | missing]}
          end

        true ->
          case Store.stream(store, did, cid) do
            {:ok, body} -> {[{row.cid, body} | stored], quarantined, missing}
            {:error, _} -> {stored, quarantined, [row.cid | missing]}
          end
      end
    end)
    |> then(fn {s, q, m} -> {Enum.reverse(s), Enum.reverse(q), Enum.reverse(m)} end)
  end

  # The Store behaviour has no read from the quarantine root; the Disk adapter's
  # layout is documented (DESIGN §4.4), so read it directly there. Other adapters
  # fall back to the permanent object if the takedown left one.
  defp quarantined_stream({Aerox.Blob.Disk, opts} = store, did, cid) do
    path =
      Path.join([
        Keyword.fetch!(opts, :root),
        "quarantine",
        String.replace(did, ":", "_"),
        CID.to_string(cid)
      ])

    cond do
      File.regular?(path) -> {:ok, File.stream!(path, 65_536)}
      true -> permanent_or_error(store, did, cid)
    end
  end

  defp quarantined_stream(store, did, cid), do: permanent_or_error(store, did, cid)

  defp permanent_or_error(store, did, cid) do
    case Store.stream(store, did, cid) do
      {:ok, body} -> {:ok, body}
      _ -> :error
    end
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  # ================================================================ import

  @doc """
  Imports an opened bundle. Options: `takeover:` (insert `seq.car` rows with
  their seqs), `store:` (blob adapter), `force:` (re-import even when
  progress says done and the account is present).

  Returns `{:ok, report}`, `{:ok, :skipped}` when already done, or
  `{:error, reason}` — in which case nothing of the account was written.
  """
  @spec import(Bundle.t(), keyword) :: {:ok, report | :skipped} | {:error, term}
  def import(%Bundle{manifest: %{"did" => did}} = bundle, opts \\ []) do
    store = Keyword.get_lazy(opts, :store, &Store.adapter/0)
    takeover? = Keyword.get(opts, :takeover, false)

    cond do
      not Keyword.get(opts, :force, false) and Progress.done?(did) ->
        {:ok, :skipped}

      true ->
        if Progress.stale?(did),
          do:
            Logger.warning(
              "import #{did}: progress said done but the account is absent — re-importing"
            )

        with {:ok, parsed} <- parse(bundle, takeover?),
             :ok <- store_blobs(bundle, store, did, parsed),
             :ok <- Progress.set(did, "importing"),
             {:ok, report} <- write_rows(did, parsed, takeover?) do
          Progress.set(did, "done")
          {:ok, report}
        else
          {:error, reason} = error ->
            if Progress.get(did), do: Progress.set(did, "failed", inspect(reason))
            error
        end
    end
  end

  @doc """
  Reads and verifies everything the import needs, writing nothing: manifest
  hashes, `account.json`, `state.json`, the signing key, and the CAR through
  the kernel's verifier (DID, signature, MST structure). Also used by
  `Aerox.Interop.Verify` for the pre-import report.
  """
  @spec parse(Bundle.t(), boolean) :: {:ok, map} | {:error, term}
  def parse(%Bundle{manifest: %{"did" => did}} = bundle, takeover? \\ false) do
    with :ok <- Bundle.verify_hashes(bundle),
         {:ok, key} <- Bundle.read_file(bundle, "signing.key"),
         {:ok, account_json} <- Bundle.read_file(bundle, "account.json"),
         {:ok, account} <- decode_json(account_json, "account.json"),
         :ok <- check_account(account, did),
         {:ok, state_json} <- Bundle.read_file(bundle, "state.json"),
         {:ok, state} <- decode_json(state_json, "state.json"),
         {:ok, car} <- Bundle.read_file(bundle, "repo.car"),
         {:ok, verified} <- verify_car(car, did, key),
         {:ok, seq_rows} <- if(takeover?, do: Bundle.seq_rows(bundle), else: {:ok, []}),
         :ok <- check_seq(seq_rows, did) do
      {:ok,
       %{
         did: did,
         key: key,
         account: account,
         state: state,
         car: car,
         commit: verified.commit,
         commit_cid: verified.cid,
         records: verified.records,
         blocks: verified.blocks,
         seq_rows: seq_rows
       }}
    end
  end

  defp decode_json(text, name) do
    case Jason.decode(text) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> {:error, {:malformed, name}}
    end
  end

  defp check_account(%{"did" => did}, did), do: :ok
  defp check_account(%{"did" => other}, _), do: {:error, {:account_json_did_mismatch, other}}
  defp check_account(_, _), do: {:error, {:malformed, "account.json"}}

  defp verify_car(car, did, key) do
    with <<_::binary-size(32)>> <- key,
         keypair = Aerox.ATProto.Crypto.from_private(:k256, key),
         {:ok, root, blocks} <- CAR.decode_with_root(car),
         {:ok, result} <-
           KRepo.verify_repo_car(car,
             did: did,
             signing_key: Aerox.ATProto.Crypto.did_key(keypair)
           ),
         :ok <- check_commit_version(result.commit) do
      ^root = result.cid
      {:ok, Map.put(result, :blocks, blocks)}
    else
      k when is_binary(k) -> {:error, {:signing_key, :not_32_bytes}}
      {:error, reason} -> {:error, {:repo_car, reason}}
    end
  end

  defp check_commit_version(%{"version" => 3}), do: :ok
  defp check_commit_version(%{"version" => v}), do: {:error, {:unsupported_repo_version, v}}

  defp check_seq(rows, did) do
    case Enum.find(rows, &(&1.did != did)) do
      nil -> :ok
      row -> {:error, {:seq_car_foreign_did, row.seq, row.did}}
    end
  end

  # Blob bytes go to the store before the transaction: idempotent, and a row must
  # never describe an object that is not there (DESIGN §4.4 "row first" inverted
  # for imports, where the bytes are the given and the rows follow).
  defp store_blobs(bundle, store, did, parsed) do
    hashes = bundle.manifest["hashes"] || %{}

    Enum.reduce_while(
      Enum.map(hashes["blobs"] || [], &{"blobs", &1}) ++
        Enum.map(hashes["quarantine"] || [], &{"quarantine", &1}),
      :ok,
      fn {sub, cid_str}, :ok ->
        cid = CID.parse!(cid_str)

        result =
          with {:ok, body} <- Bundle.stream(bundle, Path.join(sub, cid_str)),
               :ok <- Store.put_permanent(store, did, cid, body) do
            if sub == "quarantine" and parsed.state["blobs"][cid_str]["takedown_ref"] != nil,
              do: Store.quarantine(store, did, cid),
              else: :ok
          end

        case result do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:blob_store, cid_str, reason}}}
        end
      end
    )
  end

  defp write_rows(did, p, takeover?) do
    Repo.transaction(fn -> do_write_rows(did, p, takeover?) end, timeout: :infinity)
    |> case do
      {:ok, report} -> {:ok, report}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in [Ecto.ConstraintError, Postgrex.Error] -> {:error, {:database, Exception.message(e)}}
  end

  defp do_write_rows(did, p, takeover?) do
    a = p.account
    state = p.state
    commit_rev = p.commit["rev"]
    now = DateTime.utc_now()

    # ---- actor / account (upstream account.sqlite) ------------------
    Repo.insert_all(
      Actor,
      [
        %{
          did: did,
          handle: a["handle"],
          signing_key: p.key,
          created_at: dt!(a["created_at"]) || now,
          takedown_ref: a["takedown_ref"],
          deactivated_at: dt!(a["deactivated_at"]),
          delete_after: dt!(a["delete_after"])
        }
      ],
      on_conflict: {:replace_all_except, [:did]},
      conflict_target: :did
    )

    if is_binary(a["email"]) and is_binary(a["password_scrypt"]) do
      Repo.insert_all(
        Account,
        [
          %{
            did: did,
            email: a["email"],
            password_scrypt: a["password_scrypt"],
            email_confirmed_at: dt!(a["email_confirmed_at"]),
            invites_disabled: a["invites_disabled"] || false
          }
        ],
        on_conflict: {:replace_all_except, [:did]},
        conflict_target: :did
      )
    else
      Repo.delete_all(from(x in Account, where: x.did == ^did))
    end

    Repo.delete_all(from(x in AppPassword, where: x.did == ^did))

    insert_chunks(
      AppPassword,
      for ap <- a["app_passwords"] || [] do
        %{
          did: did,
          name: ap["name"],
          password_scrypt: ap["password_scrypt"],
          created_at: dt!(ap["created_at"]) || now,
          privileged: ap["privileged"] || false
        }
      end
    )

    for c <- a["invite_codes"] || [] do
      Repo.insert_all(
        InviteCode,
        [
          %{
            code: c["code"],
            available_uses: c["available_uses"] || 0,
            disabled: c["disabled"] || false,
            for_account: did,
            created_by: c["created_by"] || did,
            created_at: dt!(c["created_at"]) || now
          }
        ],
        on_conflict: {:replace_all_except, [:code]},
        conflict_target: :code
      )

      uses =
        for u <- c["uses"] || [],
            do: %{code: c["code"], used_by: u["used_by"], used_at: dt!(u["used_at"]) || now}

      insert_chunks(InviteCodeUse, uses,
        on_conflict: {:replace, [:used_at]},
        conflict_target: [:code, :used_by]
      )
    end

    Repo.delete_all(from(x in AccountPref, where: x.did == ^did))

    insert_chunks(
      AccountPref,
      for(
        pref <- a["preferences"] || [],
        do: %{did: did, name: pref["name"], value: pref["value"]}
      )
    )

    # ---- repo (upstream store.sqlite), re-derived from the CAR ------
    block_revs = state["blocks"] || %{}
    root_state = state["repo_root"] || %{}
    commit_cid_str = CID.to_string(p.commit_cid)

    Repo.insert_all(
      RepoRoot,
      [
        %{
          did: did,
          cid: commit_cid_str,
          rev: commit_rev,
          indexed_at: dt!(root_state["indexed_at"]) || now
        }
      ],
      on_conflict: {:replace, [:cid, :rev, :indexed_at]},
      conflict_target: :did
    )

    block_rows =
      for {cid, bytes} <- p.blocks do
        s = CID.to_string(cid)

        %{
          did: did,
          cid: s,
          rev: block_revs[s] || commit_rev,
          size: byte_size(bytes),
          content: bytes
        }
      end

    insert_chunks(RepoBlock, block_rows, on_conflict: :nothing, conflict_target: [:did, :cid])
    car_cids = Enum.map(block_rows, & &1.cid)
    Repo.delete_all(from(b in RepoBlock, where: b.did == ^did and b.cid not in ^car_cids))

    Repo.delete_all(from(x in Record, where: x.did == ^did))
    Repo.delete_all(from(x in Backlink, where: x.did == ^did))
    Repo.delete_all(from(x in RecordBlob, where: x.did == ^did))
    record_state = state["records"] || %{}
    blocks_by_cid = Map.new(p.blocks)

    {record_rows, backlink_rows, record_blob_rows} =
      Enum.reduce(p.records, {[], [], []}, fn op, {rs, bls, rbs} ->
        {:ok, collection, rkey} = KRepo.parse_data_key(op.path)
        uri = Syntax.at_uri(did, collection, rkey)
        st = record_state[uri] || %{}
        bytes = Map.fetch!(blocks_by_cid, op.cid)

        record =
          case Data.decode_cbor(bytes) do
            {:ok, %{} = r} -> r
            _ -> Repo.rollback({:unparseable_record, uri})
          end

        row = %{
          did: did,
          collection: collection,
          rkey: rkey,
          uri: uri,
          cid: CID.to_string(op.cid),
          rev: st["rev"] || commit_rev,
          indexed_at: dt!(st["indexed_at"]) || now,
          takedown_ref: st["takedown_ref"]
        }

        links =
          for {path, link_to} <- Records.backlinks(uri, record),
              do: %{did: did, uri: uri, path: path, link_to: link_to}

        refs =
          for %{"ref" => %CID{} = c} <- Data.blob_refs(record),
              uniq: true,
              do: %{did: did, blob_cid: CID.to_string(c), record_uri: uri}

        {[row | rs], links ++ bls, refs ++ rbs}
      end)

    insert_chunks(Record, Enum.reverse(record_rows))
    insert_chunks(Backlink, backlink_rows, on_conflict: :nothing)
    insert_chunks(RecordBlob, Enum.uniq(record_blob_rows), on_conflict: :nothing)

    blob_state = state["blobs"] || %{}
    Repo.delete_all(from(b in Blob, where: b.did == ^did and b.cid not in ^Map.keys(blob_state)))

    blob_rows =
      for {cid, b} <- blob_state do
        %{
          did: did,
          cid: cid,
          mime_type: b["mime_type"] || "application/octet-stream",
          size: b["size"] || 0,
          temp_key: nil,
          created_at: dt!(b["created_at"]) || now,
          takedown_ref: b["takedown_ref"]
        }
      end

    insert_chunks(Blob, blob_rows,
      on_conflict: {:replace, [:mime_type, :size, :temp_key, :created_at, :takedown_ref]},
      conflict_target: [:did, :cid]
    )

    # ---- sequencer (takeover) ----------------------------------------
    seq_count =
      if takeover? and p.seq_rows != [] do
        seqs = Enum.map(p.seq_rows, & &1.seq)

        foreign =
          Repo.all(
            from(s in RepoSeq, where: s.seq in ^seqs and s.did != ^did, select: s.seq, limit: 5)
          )

        if foreign != [], do: Repo.rollback({:seq_taken_by_other_did, foreign})
        insert_chunks(RepoSeq, p.seq_rows, on_conflict: :nothing, conflict_target: :seq)
        length(p.seq_rows)
      else
        0
      end

    %{
      did: did,
      records: length(record_rows),
      blocks: length(block_rows),
      blobs: map_size(blob_state),
      seq_events: seq_count,
      commit_cid: commit_cid_str,
      rev: commit_rev
    }
  end

  defp insert_chunks(_schema, [], _opts), do: :ok

  defp insert_chunks(schema, rows, opts) do
    rows |> Enum.chunk_every(200) |> Enum.each(&Repo.insert_all(schema, &1, opts))
  end

  defp insert_chunks(schema, rows), do: insert_chunks(schema, rows, [])

  defp dt!(nil), do: nil

  defp dt!(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> usec(dt)
      _ -> raise ArgumentError, "invalid datetime #{inspect(str)}"
    end
  end

  # Ecto's :utc_datetime_usec insists on microsecond precision; upstream writes milliseconds.
  @doc false
  def usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}

  # ================================================================ helpers

  @doc "The commit block of an account as stored (for `Aerox.Interop.Verify`)."
  @spec commit_block(String.t()) :: {:ok, CID.t(), binary} | {:error, term}
  def commit_block(did) do
    with %RepoRoot{} = root <- Repo.get(RepoRoot, did) || {:error, :no_repo},
         cid = CID.parse!(root.cid),
         {:ok, bytes} <-
           Aerox.ATProto.Blockstore.get(Blockstore.new(did), cid) |> ok_or(:missing_commit_block) do
      {:ok, cid, bytes}
    end
  end

  defp ok_or({:ok, v}, _), do: {:ok, v}
  defp ok_or(:error, reason), do: {:error, reason}

  @doc false
  def decode_record(bytes), do: DagCBOR.decode(bytes)
end
