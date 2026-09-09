defmodule AeroxWeb.PDS.RepoController do
  @moduledoc "`com.atproto.repo.*`: record CRUD, applyWrites, uploadBlob, describeRepo, importRepo, listMissingBlobs."
  use AeroxWeb, :controller
  use AeroxWeb.Plugs.XRPCError
  import AeroxWeb.XRPC
  alias Aerox.ATProto.{CID, Data, Syntax}
  alias Aerox.PDS.{Accounts, Blobs, Config, Records}
  alias Aerox.PDS.Records.Prepare
  alias AeroxWeb.Plugs.RateLimit
  alias AeroxWeb.XRPC.Error

  # ---------------------------------------------------------------- writes

  def create_record(conn, _) do
    input = input!(conn, "com.atproto.repo.createRecord")
    did = writer!(conn, input["repo"])

    with {:ok, conn} <- RateLimit.consume(conn, :repo_write, 3) do
      write =
        prepare!(
          Prepare.create(did, input["collection"], Data.to_json(input["record"]),
            rkey: input["rkey"],
            validate: input["validate"]
          )
        )

      # a duplicate like/follow/repost of the same subject replaces the old one (upstream backlink conflicts)
      deletions =
        if input["validate"] != false,
          do:
            did
            |> Records.backlink_conflicts(write.uri, write.collection, write.record)
            |> Enum.map(&delete_for_uri(did, &1)),
          else: []

      commit = process!(did, deletions ++ [write], swap_commit: parse_cid(input["swapCommit"]))

      respond(conn, %{
        "uri" => write.uri,
        "cid" => CID.to_string(write.cid),
        "commit" => commit_json(commit),
        "validationStatus" => Atom.to_string(write.validation_status)
      })
    end
  end

  def put_record(conn, _) do
    input = input!(conn, "com.atproto.repo.putRecord")
    did = writer!(conn, input["repo"])

    with {:ok, conn} <- RateLimit.consume(conn, :repo_write, 2) do
      collection = input["collection"]
      rkey = input["rkey"]
      current = Records.get_record(did, collection, rkey, include_taken_down: true)

      swap_record =
        if Map.has_key?(input, "swapRecord"), do: parse_cid(input["swapRecord"]), else: :unset

      record = Data.to_json(input["record"])

      write =
        case current do
          {:ok, _} ->
            prepare!(
              Prepare.update(did, collection, rkey, record,
                validate: input["validate"],
                swap_cid: swap_record
              )
            )

          {:error, :not_found} ->
            prepare!(
              Prepare.create(did, collection, record,
                rkey: rkey,
                validate: input["validate"],
                swap_cid: swap_record
              )
            )
        end

      new_cid = CID.to_string(write.cid)

      case current do
        {:ok, %{cid: ^new_cid}} ->
          # no-op: the record is unchanged
          respond(conn, %{
            "uri" => write.uri,
            "cid" => CID.to_string(write.cid),
            "validationStatus" => Atom.to_string(write.validation_status)
          })

        _ ->
          commit = process!(did, [write], swap_commit: parse_cid(input["swapCommit"]))

          respond(conn, %{
            "uri" => write.uri,
            "cid" => CID.to_string(write.cid),
            "commit" => commit_json(commit),
            "validationStatus" => Atom.to_string(write.validation_status)
          })
      end
    end
  end

  def delete_record(conn, _) do
    input = input!(conn, "com.atproto.repo.deleteRecord")
    did = writer!(conn, input["repo"])

    with {:ok, conn} <- RateLimit.consume(conn, :repo_write, 1) do
      swap_record =
        if Map.has_key?(input, "swapRecord"), do: parse_cid(input["swapRecord"]), else: :unset

      {:ok, write} =
        Prepare.delete(did, input["collection"], input["rkey"], swap_cid: swap_record)

      case Records.get_record(did, input["collection"], input["rkey"], include_taken_down: true) do
        {:error, :not_found} ->
          respond(conn, %{})

        {:ok, _} ->
          commit = process!(did, [write], swap_commit: parse_cid(input["swapCommit"]))
          respond(conn, %{"commit" => commit_json(commit)})
      end
    end
  end

  def apply_writes(conn, _) do
    input = input!(conn, "com.atproto.repo.applyWrites")
    did = writer!(conn, input["repo"])
    writes = input["writes"] || []
    if length(writes) > 200, do: raise(Error.invalid_request("Too many writes. Max: 200"))

    points =
      Enum.reduce(writes, 0, fn w, n ->
        n +
          case w["$type"] do
            "com.atproto.repo.applyWrites#create" -> 3
            "com.atproto.repo.applyWrites#update" -> 2
            _ -> 1
          end
      end)

    with {:ok, conn} <- RateLimit.consume(conn, :repo_write, points) do
      prepared =
        Enum.map(writes, fn w ->
          case w["$type"] do
            "com.atproto.repo.applyWrites#create" ->
              prepare!(
                Prepare.create(did, w["collection"], Data.to_json(w["value"]),
                  rkey: w["rkey"],
                  validate: input["validate"]
                )
              )

            "com.atproto.repo.applyWrites#update" ->
              prepare!(
                Prepare.update(did, w["collection"], w["rkey"], Data.to_json(w["value"]),
                  validate: input["validate"]
                )
              )

            "com.atproto.repo.applyWrites#delete" ->
              elem(Prepare.delete(did, w["collection"], w["rkey"]), 1)

            other ->
              raise Error.invalid_request("Invalid write type: #{inspect(other)}")
          end
        end)

      commit = process!(did, prepared, swap_commit: parse_cid(input["swapCommit"]))

      results =
        Enum.map(prepared, fn
          %{action: :create} = w ->
            %{
              "$type" => "com.atproto.repo.applyWrites#createResult",
              "uri" => w.uri,
              "cid" => CID.to_string(w.cid),
              "validationStatus" => Atom.to_string(w.validation_status)
            }

          %{action: :update} = w ->
            %{
              "$type" => "com.atproto.repo.applyWrites#updateResult",
              "uri" => w.uri,
              "cid" => CID.to_string(w.cid),
              "validationStatus" => Atom.to_string(w.validation_status)
            }

          %{action: :delete} ->
            %{"$type" => "com.atproto.repo.applyWrites#deleteResult"}
        end)

      respond(conn, %{"commit" => commit_json(commit), "results" => results})
    end
  end

  defp writer!(conn, repo) do
    %{did: did} = require_auth!(conn)

    account =
      Accounts.get_account(repo) ||
        raise(Error.invalid_request("Could not find repo: #{repo}", "RepoNotFound"))

    if account.did != did, do: raise(Error.auth_required())
    did
  end

  defp prepare!({:ok, write}), do: write
  defp prepare!({:error, {_, msg}}), do: raise(Error.invalid_request(msg))

  defp process!(did, writes, opts) do
    case Records.process_writes(did, writes, opts) do
      {:ok, commit} ->
        blobs = writes |> Enum.flat_map(&Map.get(&1, :blobs, []))

        case Blobs.process_write_blobs(did, blobs) do
          :ok ->
            commit

          {:error, {:blob_not_found, cid}} ->
            raise Error.invalid_request("Could not find blob: #{cid}", "BlobNotFound")

          {:error, {:invalid_blob, msg}} ->
            raise Error.invalid_request(msg)

          {:error, other} ->
            raise Error.internal(inspect(other))
        end

      {:error, %Records.Error{kind: :invalid_swap, message: msg}} ->
        raise Error.invalid_request(msg, "InvalidSwap")

      {:error, %Records.Error{message: msg}} ->
        raise Error.invalid_request(msg)

      {:error, other} ->
        raise Error.internal(inspect(other))
    end
  end

  defp delete_for_uri(did, uri) do
    {:ok, %{collection: c, rkey: r}} = Syntax.parse_at_uri(uri)
    {:ok, w} = Prepare.delete(did, c, r)
    w
  end

  defp parse_cid(nil), do: nil

  defp parse_cid(str) when is_binary(str) do
    case CID.parse(str) do
      {:ok, cid} -> cid
      _ -> raise Error.invalid_request("Invalid CID: #{str}")
    end
  end

  defp commit_json(%{cid: cid, rev: rev}), do: %{"cid" => CID.to_string(cid), "rev" => rev}

  # ----------------------------------------------------------------- reads

  def get_record(conn, _) do
    params = params!(conn, "com.atproto.repo.getRecord")
    uri_str = fn did -> Syntax.at_uri(did, params["collection"], params["rkey"]) end

    case Accounts.did_for_actor(params["repo"]) do
      nil ->
        {:error, Error.invalid_request("Could not locate record")}

      did ->
        case Records.get_record(did, params["collection"], params["rkey"], cid: params["cid"]) do
          {:ok, record} ->
            respond(conn, %{"uri" => record.uri, "cid" => record.cid, "value" => record.value})

          {:error, :not_found} ->
            {:error,
             Error.invalid_request("Could not locate record: #{uri_str.(did)}", "RecordNotFound")}
        end
    end
  end

  def list_records(conn, _) do
    params = params!(conn, "com.atproto.repo.listRecords")

    did =
      Accounts.did_for_actor(params["repo"]) ||
        raise(Error.invalid_request("Could not find repo: #{params["repo"]}"))

    records =
      Records.list_records(did, params["collection"],
        limit: params["limit"],
        cursor: params["cursor"],
        reverse: params["reverse"],
        rkey_start: params["rkeyStart"],
        rkey_end: params["rkeyEnd"]
      )

    last = List.last(records)

    respond(
      conn,
      %{
        "records" => Enum.map(records, &%{"uri" => &1.uri, "cid" => &1.cid, "value" => &1.value}),
        "cursor" => last && last.rkey
      }
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()
    )
  end

  def describe_repo(conn, _) do
    params = params!(conn, "com.atproto.repo.describeRepo")

    account =
      Accounts.get_account(params["repo"]) ||
        raise(
          Error.invalid_request("Could not find repo for DID: #{params["repo"]}", "RepoNotFound")
        )

    doc =
      case Aerox.Identity.resolve_did(Aerox.PDS.Identity, account.did) do
        {:ok, doc} ->
          doc

        {:error, reason} ->
          raise Error.invalid_request("Could not resolve DID: #{inspect(reason)}")
      end

    respond(conn, %{
      "handle" => account.handle || "handle.invalid",
      "did" => account.did,
      "didDoc" => doc,
      "collections" => Records.list_collections(account.did),
      "handleIsCorrect" => Aerox.ATProto.Identity.handle(doc) == account.handle
    })
  end

  # ----------------------------------------------------------------- blobs

  def upload_blob(conn, _) do
    %{did: did} = require_auth!(conn, kinds: [:access, :service])

    with {:ok, conn} <- RateLimit.consume(conn, :upload_blob, 1) do
      mime =
        conn
        |> get_req_header("content-type")
        |> List.first()
        |> then(&(&1 && &1 |> String.split(";") |> hd() |> String.trim()))

      limit = Config.blob_upload_limit()

      # The body is streamed to a spool file (never held in memory), then the
      # spool is streamed into the blob store while being hashed and sniffed.
      spool =
        Path.join(
          System.tmp_dir!(),
          "aerox-upload-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
        )

      {:ok, conn} = spool_body(conn, spool, limit)
      chunks = File.stream!(spool, 65_536)

      result =
        with {:ok, meta} <- Blobs.upload(did, mime, chunks),
             {:ok, ref} <- Blobs.track(did, meta) do
          respond(conn, %{"blob" => ref})
        else
          {:error, :takendown} ->
            {:error, Error.invalid_request("Blob has been takendown, cannot re-upload")}

          {:error, reason} ->
            {:error, Error.internal("upload failed: #{inspect(reason)}")}
        end

      File.rm(spool)
      result
    end
  end

  defp spool_body(conn, path, limit) do
    File.open!(path, [:write, :binary], fn file -> spool_loop(conn, file, limit, 0) end)
  end

  defp spool_loop(conn, file, limit, total) do
    case Plug.Conn.read_body(conn, length: 1_000_000, read_length: 65_536) do
      {:ok, data, conn} ->
        check_size!(total + byte_size(data), limit)
        IO.binwrite(file, data)
        {:ok, conn}

      {:more, data, conn} ->
        check_size!(total + byte_size(data), limit)
        IO.binwrite(file, data)
        spool_loop(conn, file, limit, total + byte_size(data))

      {:error, reason} ->
        raise Error.invalid_request("Could not read upload: #{inspect(reason)}")
    end
  end

  defp check_size!(size, limit) do
    if size > limit,
      do:
        raise(
          Error.invalid_request(
            "This file is too large. It is #{size} bytes but the maximum size is #{limit} bytes.",
            "BlobTooLarge"
          )
        )
  end

  def list_missing_blobs(conn, _) do
    %{did: did} = require_auth!(conn)
    params = params!(conn, "com.atproto.repo.listMissingBlobs")
    blobs = Blobs.missing(did, limit: params["limit"], cursor: params["cursor"])
    last = List.last(blobs)

    respond(
      conn,
      %{
        "blobs" => Enum.map(blobs, &%{"cid" => &1.cid, "recordUri" => &1.record_uri}),
        "cursor" => last && last.cid
      }
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()
    )
  end

  def import_repo(conn, _) do
    %{did: did} = require_auth!(conn, scopes: Aerox.PDS.Sessions.access_full())

    if not Config.accepting_imports?(),
      do: raise(Error.invalid_request("Service is not accepting repo imports"))

    {:ok, body, conn} = read_all(conn, Config.max_import_bytes())

    case Aerox.PDS.Import.import_car(did, body) do
      :ok -> send_resp(conn, 200, "")
      {:error, msg} when is_binary(msg) -> {:error, Error.invalid_request(msg)}
      {:error, other} -> {:error, Error.invalid_request(inspect(other))}
    end
  end

  defp read_all(conn, limit, acc \\ []) do
    case Plug.Conn.read_body(conn, length: 8_000_000, read_length: 1_000_000) do
      {:ok, data, conn} -> finish(conn, [data | acc], limit)
      {:more, data, conn} -> read_all(conn, limit, [data | acc])
      {:error, reason} -> raise Error.invalid_request("Could not read body: #{inspect(reason)}")
    end
  end

  defp finish(conn, acc, limit) do
    body = acc |> Enum.reverse() |> IO.iodata_to_binary()
    if byte_size(body) > limit, do: raise(Error.invalid_request("Import too large"))
    {:ok, body, conn}
  end
end
