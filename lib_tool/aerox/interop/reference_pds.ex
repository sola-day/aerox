defmodule Aerox.Interop.ReferencePds do
  @moduledoc """
  The reference-PDS adapter: a stock `ghcr.io/bluesky-social/pds` `<data>`
  directory ⇄ bundle (DESIGN §13.2, mapping table). `MIX_ENV=tool` only
  (STRUCTURE §5): this is the one module that names `Exqlite`.

  Reads: `account.sqlite` (account, actor, app_password, invite_code[_use]),
  `sequencer.sqlite` (`repo_seq` for the DID, takeover mode),
  `actors/<sha256(did)[0:2]>/<did>/{store.sqlite,key}` and the blob
  directory (`PDS_BLOBSTORE_DISK_LOCATION`, `<data>/blocks` in the official
  installer; `<data>/blobs` is tried next). Sessions, OAuth state and email
  tokens are not carried. `repo.car` is written by the kernel's CAR writer
  from the verbatim `repo_block` bytes, walking from `repo_root.cid`; every
  table is re-derived from it on import.

  Writes: the inverse, producing a `<data>` directory the pinned image boots
  from (`Aerox.Interop.ReferencePds.Schema` for the DDL and Kysely rows).
  Read the source from a consistent snapshot (`.backup`, or a stopped PDS).
  """
  alias Aerox.ATProto.{CAR, CID, Data, Syntax}
  alias Aerox.ATProto.Blockstore.Memory
  alias Aerox.ATProto.Repo, as: KRepo
  alias Aerox.Interop.Bundle
  alias Aerox.Interop.ReferencePds.{Schema, Sqlite}
  require Logger

  @type data_dir :: Path.t()

  # ================================================================ read

  @doc "Every `(did, handle)` in `account.sqlite`'s `actor` table — the only authoritative list."
  @spec list_accounts(data_dir) :: [%{did: String.t(), handle: String.t() | nil}]
  def list_accounts(data) do
    with_db(Path.join(data, "account.sqlite"), fn conn ->
      conn
      |> Sqlite.query("SELECT did, handle FROM actor ORDER BY did")
      |> Enum.map(&%{did: &1["did"], handle: &1["handle"]})
    end)
  end

  @doc """
  Exports one account from `data` into `out_dir`. Options: `takeover:`,
  `blobs_dir:`, `host:` (the source PDS hostname, recorded in the manifest),
  `pds_version:`, plus `Aerox.Interop.Bundle.write/3`'s.
  """
  @spec export(data_dir, String.t(), Path.t(), keyword) :: {:ok, map} | {:error, term}
  def export(data, did, out_dir, opts \\ []) do
    with {:ok, contents} <- contents(data, did, opts) do
      Bundle.write(
        out_dir,
        contents,
        Keyword.take(opts, [:recipients, :insecure_plaintext, :signer, :chunk_size])
      )
    end
  end

  @doc "Bundle contents for `did`, read from the reference layout."
  @spec contents(data_dir, String.t(), keyword) :: {:ok, Bundle.contents()} | {:error, term}
  def contents(data, did, opts \\ []) do
    actor_dir = actor_dir(data, did)
    store_path = Path.join(actor_dir, "store.sqlite")
    key_path = Path.join(actor_dir, "key")

    with true <- File.regular?(store_path) || {:error, {:no_actor_store, did}},
         {:ok, key} <- File.read(key_path),
         true <- byte_size(key) == 32 || {:error, {:bad_key_file, key_path}},
         {:ok, acct} <- account_rows(data, did),
         {:ok, store} <- store_rows(store_path, did) do
      blobs_dir = blobs_dir(data, opts)
      {stored, quarantined, missing} = blob_files(blobs_dir, did, store.blobs)

      if missing != [],
        do:
          Logger.warning(
            "#{did}: #{length(missing)} blob object(s) not under #{blobs_dir}: #{inspect(missing)}"
          )

      seq =
        if Keyword.get(opts, :takeover, false) do
          rows = seq_rows(data, did)
          {Bundle.encode_seq(rows), length(rows)}
        end

      {:ok,
       %{
         did: did,
         handle: acct.actor["handle"],
         source: %{
           "impl" => "reference-pds",
           "version" => Keyword.get(opts, :pds_version, "unknown"),
           "host" => Keyword.get(opts, :host)
         },
         account: Map.put(account_json(did, acct), "preferences", preferences(store.prefs)),
         signing_key: key,
         repo_car: store.car,
         state: %{
           "repo_root" => %{
             "cid" => store.root["cid"],
             "rev" => store.root["rev"],
             "indexed_at" => norm_dt(store.root["indexedAt"])
           },
           "records" =>
             Map.new(store.records, fn r ->
               {r["uri"],
                %{
                  "cid" => r["cid"],
                  "rev" => r["repoRev"],
                  "indexed_at" => norm_dt(r["indexedAt"]),
                  "takedown_ref" => r["takedownRef"]
                }}
             end),
           "blobs" =>
             Map.new(store.blobs, fn b ->
               {b["cid"],
                %{
                  "mime_type" => b["mimeType"],
                  "size" => b["size"],
                  "created_at" => norm_dt(b["createdAt"]),
                  "takedown_ref" => b["takedownRef"]
                }}
             end),
           "blocks" => store.block_revs
         },
         counts: %{records: length(store.records), blocks: store.block_count},
         blobs: stored,
         quarantine: quarantined,
         seq: seq
       }}
    end
  end

  defp account_rows(data, did) do
    with_db(Path.join(data, "account.sqlite"), fn conn ->
      case Sqlite.query(conn, "SELECT * FROM actor WHERE did = ?", [did]) do
        [] ->
          {:error, {:actor_not_found, did}}

        [actor] ->
          account = List.first(Sqlite.query(conn, "SELECT * FROM account WHERE did = ?", [did]))

          app_passwords =
            Sqlite.query(conn, "SELECT * FROM app_password WHERE did = ? ORDER BY name", [did])

          codes =
            Sqlite.query(conn, "SELECT * FROM invite_code WHERE forAccount = ? ORDER BY code", [
              did
            ])

          uses =
            for c <- codes,
                u <-
                  Sqlite.query(
                    conn,
                    "SELECT * FROM invite_code_use WHERE code = ? ORDER BY usedAt",
                    [c["code"]]
                  ),
                do: u

          {:ok,
           %{
             actor: actor,
             account: account,
             app_passwords: app_passwords,
             codes: codes,
             uses: uses
           }}
      end
    end)
  end

  defp account_json(did, a) do
    %{
      "did" => did,
      "handle" => a.actor["handle"],
      "created_at" => norm_dt(a.actor["createdAt"]),
      "takedown_ref" => a.actor["takedownRef"],
      "deactivated_at" => norm_dt(a.actor["deactivatedAt"]),
      "delete_after" => norm_dt(a.actor["deleteAfter"]),
      "email" => a.account && a.account["email"],
      "email_confirmed_at" => norm_dt(a.account && a.account["emailConfirmedAt"]),
      "password_scrypt" => a.account && a.account["passwordScrypt"],
      "invites_disabled" => Sqlite.bool(a.account && a.account["invitesDisabled"]),
      "app_passwords" =>
        Enum.map(a.app_passwords, fn p ->
          %{
            "name" => p["name"],
            "password_scrypt" => p["passwordScrypt"],
            "created_at" => norm_dt(p["createdAt"]),
            "privileged" => Sqlite.bool(p["privileged"])
          }
        end),
      "invite_codes" =>
        Enum.map(a.codes, fn c ->
          %{
            "code" => c["code"],
            "available_uses" => c["availableUses"],
            "disabled" => Sqlite.bool(c["disabled"]),
            "created_by" => c["createdBy"],
            "created_at" => norm_dt(c["createdAt"]),
            "uses" =>
              for(
                u <- a.uses,
                u["code"] == c["code"],
                do: %{"used_by" => u["usedBy"], "used_at" => norm_dt(u["usedAt"])}
              )
          }
        end),
      "preferences" => []
    }
  end

  defp store_rows(path, did) do
    with_db(path, fn conn ->
      with [root] <-
             Sqlite.query(conn, "SELECT * FROM repo_root WHERE did = ?", [did])
             |> non_empty({:no_repo_root, did}),
           {:ok, root_cid} <- CID.parse(root["cid"]) do
        blocks =
          conn
          |> Sqlite.query("SELECT cid, repoRev, content FROM repo_block")
          |> Enum.map(fn b -> {CID.parse!(b["cid"]), b["content"], b["repoRev"]} end)

        bs = Memory.new(Enum.map(blocks, fn {c, bytes, _} -> {c, bytes} end))
        revs = Map.new(blocks, fn {c, _, rev} -> {CID.to_string(c), rev} end)

        with {:ok, ordered} <- KRepo.full_repo_blocks(bs, root_cid) do
          records = Sqlite.query(conn, "SELECT * FROM record ORDER BY uri")
          blobs = Sqlite.query(conn, "SELECT * FROM blob ORDER BY cid")
          prefs = Sqlite.query(conn, "SELECT name, valueJson FROM account_pref ORDER BY id")

          {:ok,
           %{
             root: root,
             car: CAR.encode(root_cid, ordered),
             block_count: length(ordered),
             block_revs:
               Map.new(ordered, fn {c, _} -> {CID.to_string(c), revs[CID.to_string(c)]} end),
             records: records,
             blobs: blobs,
             prefs: prefs
           }}
        end
      end
    end)
    |> case do
      {:ok, store} -> {:ok, store}
      {:error, _} = e -> e
    end
  end

  defp non_empty([], reason), do: {:error, reason}
  defp non_empty(rows, _), do: rows

  # The account_pref rows live in store.sqlite; they travel in account.json.
  defp preferences(rows),
    do: Enum.map(rows, &%{"name" => &1["name"], "value" => Jason.decode!(&1["valueJson"])})

  defp blob_files(blobs_dir, did, blob_rows) do
    Enum.reduce(blob_rows, {[], [], []}, fn b, {s, q, m} ->
      cid = b["cid"]
      stored = Path.join([blobs_dir, did, cid])
      quarantined = Path.join([blobs_dir, "quarantine", did, cid])

      cond do
        b["tempKey"] != nil ->
          {s, q, m}

        b["takedownRef"] != nil and File.regular?(quarantined) ->
          {s, [{cid, File.stream!(quarantined, 65_536)} | q], m}

        File.regular?(stored) ->
          {[{cid, File.stream!(stored, 65_536)} | s], q, m}

        true ->
          {s, q, [cid | m]}
      end
    end)
    |> then(fn {s, q, m} -> {Enum.reverse(s), Enum.reverse(q), Enum.reverse(m)} end)
  end

  defp seq_rows(data, did) do
    path = Path.join(data, "sequencer.sqlite")

    if File.regular?(path) do
      with_db(path, fn conn ->
        conn
        |> Sqlite.query(
          "SELECT seq, did, eventType, event, invalidated, sequencedAt FROM repo_seq WHERE did = ? ORDER BY seq",
          [did]
        )
        |> Enum.map(fn r ->
          {:ok, at, _} = DateTime.from_iso8601(r["sequencedAt"])

          %{
            seq: r["seq"],
            did: r["did"],
            event_type: r["eventType"],
            event: r["event"],
            invalidated: Sqlite.bool(r["invalidated"]),
            sequenced_at: at
          }
        end)
      end)
    else
      []
    end
  end

  # ================================================================ write

  @doc """
  Writes an opened bundle into a reference-PDS `<data>` directory for
  `pds_version:` (required, pinned — see `Schema`). Options: `blobs_dir:`
  (default `<data>/blocks`), `takeover:` (write `repo_seq`).
  Existing files are opened and upserted, so several bundles build one
  directory.
  """
  @spec write(Bundle.t(), data_dir, keyword) :: {:ok, map} | {:error, term}
  def write(%Bundle{manifest: %{"did" => did}} = bundle, data, opts) do
    version = Keyword.get(opts, :pds_version) || "unset"

    with {:ok, account_spec} <- Schema.for(version, :account),
         {:ok, seq_spec} <- Schema.for(version, :sequencer),
         {:ok, actor_spec} <- Schema.for(version, :actor),
         {:ok, parsed} <-
           Aerox.Interop.Bundle.Postgres.parse(bundle, Keyword.get(opts, :takeover, false)) do
      File.mkdir_p!(data)
      now = Syntax.format_datetime(DateTime.utc_now())
      write_account_db(Path.join(data, "account.sqlite"), account_spec, now, did, parsed)

      if Keyword.get(opts, :takeover, false),
        do: write_sequencer_db(Path.join(data, "sequencer.sqlite"), seq_spec, now, parsed)

      dir = actor_dir(data, did)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "key"), parsed.key)
      File.chmod!(Path.join(dir, "key"), 0o600)
      counts = write_actor_db(Path.join(dir, "store.sqlite"), actor_spec, now, did, parsed)
      blobs = write_blobs(bundle, blobs_dir(data, opts), did)

      {:ok,
       Map.merge(counts, %{
         did: did,
         blobs: blobs,
         seq_events: if(opts[:takeover], do: length(parsed.seq_rows), else: 0)
       })}
    end
  end

  defp write_account_db(path, spec, now, did, %{account: a} = p) do
    with_db(path, fn conn ->
      ensure_schema(conn, spec, now)

      Sqlite.transaction(conn, fn ->
        Sqlite.upsert(conn, "actor", %{
          "did" => did,
          "handle" => a["handle"],
          "createdAt" => ref_dt(a["created_at"], now),
          "takedownRef" => a["takedown_ref"],
          "deactivatedAt" => ref_dt(a["deactivated_at"]),
          "deleteAfter" => ref_dt(a["delete_after"])
        })

        if is_binary(a["email"]) and is_binary(a["password_scrypt"]) do
          Sqlite.upsert(conn, "account", %{
            "did" => did,
            "email" => a["email"],
            "passwordScrypt" => a["password_scrypt"],
            "emailConfirmedAt" => ref_dt(a["email_confirmed_at"]),
            "invitesDisabled" => Sqlite.int(a["invites_disabled"])
          })
        end

        Sqlite.exec(conn, "DELETE FROM app_password WHERE did = ?", [did])

        for ap <- a["app_passwords"] || [] do
          Sqlite.upsert(conn, "app_password", %{
            "did" => did,
            "name" => ap["name"],
            "passwordScrypt" => ap["password_scrypt"],
            "createdAt" => ref_dt(ap["created_at"], now),
            "privileged" => Sqlite.int(ap["privileged"])
          })
        end

        for c <- a["invite_codes"] || [] do
          Sqlite.upsert(conn, "invite_code", %{
            "code" => c["code"],
            "availableUses" => c["available_uses"] || 0,
            "disabled" => Sqlite.int(c["disabled"]),
            "forAccount" => did,
            "createdBy" => c["created_by"] || did,
            "createdAt" => ref_dt(c["created_at"], now)
          })

          for u <- c["uses"] || [] do
            Sqlite.upsert(conn, "invite_code_use", %{
              "code" => c["code"],
              "usedBy" => u["used_by"],
              "usedAt" => ref_dt(u["used_at"], now)
            })
          end
        end

        Sqlite.upsert(conn, "repo_root", %{
          "did" => did,
          "cid" => CID.to_string(p.commit_cid),
          "rev" => p.commit["rev"],
          "indexedAt" => ref_dt(get_in(p.state, ["repo_root", "indexed_at"]), now)
        })
      end)
    end)
  end

  defp write_sequencer_db(path, spec, now, p) do
    with_db(path, fn conn ->
      ensure_schema(conn, spec, now)

      Sqlite.transaction(conn, fn ->
        for r <- p.seq_rows do
          Sqlite.exec(
            conn,
            ~s|INSERT OR IGNORE INTO "repo_seq" ("seq", "did", "eventType", "event", "invalidated", "sequencedAt") VALUES (?, ?, ?, ?, ?, ?)|,
            [
              r.seq,
              r.did,
              r.event_type,
              {:blob, r.event},
              Sqlite.int(r.invalidated),
              Syntax.format_datetime(r.sequenced_at)
            ]
          )
        end
      end)
    end)
  end

  defp write_actor_db(path, spec, now, did, p) do
    with_db(path, fn conn ->
      ensure_schema(conn, spec, now)
      rev = p.commit["rev"]
      block_revs = p.state["blocks"] || %{}
      blocks_by_cid = Map.new(p.blocks)

      Sqlite.transaction(conn, fn ->
        Sqlite.upsert(conn, "repo_root", %{
          "did" => did,
          "cid" => CID.to_string(p.commit_cid),
          "rev" => rev,
          "indexedAt" => ref_dt(get_in(p.state, ["repo_root", "indexed_at"]), now)
        })

        car_cids = for {cid, _} <- p.blocks, do: CID.to_string(cid)

        for {cid, bytes} <- p.blocks do
          s = CID.to_string(cid)

          Sqlite.exec(
            conn,
            ~s|INSERT OR IGNORE INTO "repo_block" ("cid", "repoRev", "size", "content") VALUES (?, ?, ?, ?)|,
            [s, block_revs[s] || rev, byte_size(bytes), {:blob, bytes}]
          )
        end

        # stale blocks of a previous write of this account
        for %{"cid" => s} <- Sqlite.query(conn, "SELECT cid FROM repo_block"),
            s not in car_cids do
          Sqlite.exec(conn, "DELETE FROM repo_block WHERE cid = ?", [s])
        end

        Sqlite.execute(conn, "DELETE FROM record")
        Sqlite.execute(conn, "DELETE FROM backlink")
        Sqlite.execute(conn, "DELETE FROM record_blob")
        record_state = p.state["records"] || %{}

        for op <- p.records do
          {:ok, collection, rkey} = KRepo.parse_data_key(op.path)
          uri = Syntax.at_uri(did, collection, rkey)
          st = record_state[uri] || %{}

          Sqlite.upsert(conn, "record", %{
            "uri" => uri,
            "cid" => CID.to_string(op.cid),
            "collection" => collection,
            "rkey" => rkey,
            "repoRev" => st["rev"] || rev,
            "indexedAt" => ref_dt(st["indexed_at"], now),
            "takedownRef" => st["takedown_ref"]
          })

          {:ok, record} = Data.decode_cbor(Map.fetch!(blocks_by_cid, op.cid))

          for {path, link_to} <- Aerox.PDS.Records.backlinks(uri, record) do
            Sqlite.upsert(conn, "backlink", %{"uri" => uri, "path" => path, "linkTo" => link_to})
          end

          for %{"ref" => %CID{} = c} <- Data.blob_refs(record) do
            Sqlite.upsert(conn, "record_blob", %{
              "blobCid" => CID.to_string(c),
              "recordUri" => uri
            })
          end
        end

        Sqlite.execute(conn, "DELETE FROM blob")

        for {cid, b} <- p.state["blobs"] || %{} do
          Sqlite.upsert(conn, "blob", %{
            "cid" => cid,
            "mimeType" => b["mime_type"] || "application/octet-stream",
            "size" => b["size"] || 0,
            "tempKey" => nil,
            "width" => nil,
            "height" => nil,
            "createdAt" => ref_dt(b["created_at"], now),
            "takedownRef" => b["takedown_ref"]
          })
        end

        Sqlite.execute(conn, "DELETE FROM account_pref")

        for pref <- p.account["preferences"] || [] do
          Sqlite.exec(conn, ~s|INSERT INTO "account_pref" ("name", "valueJson") VALUES (?, ?)|, [
            pref["name"],
            Jason.encode!(pref["value"])
          ])
        end
      end)

      %{records: length(p.records), blocks: length(p.blocks)}
    end)
  end

  defp write_blobs(bundle, blobs_dir, did) do
    hashes = bundle.manifest["hashes"] || %{}

    for {sub, target} <- [
          {"blobs", Path.join(blobs_dir, did)},
          {"quarantine", Path.join([blobs_dir, "quarantine", did])}
        ],
        cid <- hashes[sub] || [],
        reduce: 0 do
      n ->
        File.mkdir_p!(target)
        {:ok, stream} = Bundle.stream(bundle, Path.join(sub, cid))
        tmp = Path.join(target, cid <> ".part")
        stream |> Stream.into(File.stream!(tmp)) |> Stream.run()
        File.rename!(tmp, Path.join(target, cid))
        n + 1
    end
  end

  defp ensure_schema(conn, %{ddl: ddl, migrations: names}, now) do
    unless Sqlite.table?(conn, "kysely_migration") do
      Enum.each(Schema.kysely_ddl() ++ ddl, &Sqlite.execute(conn, &1))

      Enum.each(
        names,
        &Sqlite.exec(
          conn,
          ~s|INSERT INTO "kysely_migration" ("name", "timestamp") VALUES (?, ?)|,
          [&1, now]
        )
      )

      Sqlite.exec(
        conn,
        ~s|INSERT INTO "kysely_migration_lock" ("id", "is_locked") VALUES ('migration_lock', 0)|
      )
    end

    present =
      conn
      |> Sqlite.query("SELECT name FROM kysely_migration ORDER BY name")
      |> Enum.map(& &1["name"])

    if present != names,
      do:
        raise(
          ArgumentError,
          "existing database has migrations #{inspect(present)}, expected #{inspect(names)}"
        )

    :ok
  end

  # ================================================================ helpers

  @doc "`<data>/actors/<sha256(did)[0:2]>/<did>` (upstream `ActorStore`)."
  @spec actor_dir(data_dir, String.t()) :: Path.t()
  def actor_dir(data, did) do
    <<prefix::binary-size(1), _::binary>> = :crypto.hash(:sha256, did)
    Path.join([data, "actors", Base.encode16(prefix, case: :lower), did])
  end

  @doc "The blob directory: `blobs_dir:` if given, else the first of `<data>/blocks`, `<data>/blobs` that exists (default `blocks`)."
  @spec blobs_dir(data_dir, keyword) :: Path.t()
  def blobs_dir(data, opts) do
    opts[:blobs_dir] ||
      Enum.find(
        [Path.join(data, "blocks"), Path.join(data, "blobs")],
        Path.join(data, "blocks"),
        &File.dir?/1
      )
  end

  defp with_db(path, fun) do
    {:ok, conn} = Sqlite.open(path)

    try do
      fun.(conn)
    after
      Sqlite.close(conn)
    end
  end

  # upstream stores ISO-8601 strings; normalise through DateTime so both sides agree
  defp norm_dt(nil), do: nil

  defp norm_dt(str) do
    {:ok, dt, _} = DateTime.from_iso8601(str)
    DateTime.to_iso8601(dt)
  end

  defp ref_dt(value, default \\ nil)
  defp ref_dt(nil, default), do: default

  defp ref_dt(str, _default) do
    {:ok, dt, _} = DateTime.from_iso8601(str)
    Syntax.format_datetime(dt)
  end
end
