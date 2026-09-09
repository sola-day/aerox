defmodule AeroxWeb.PDS.SyncController do
  @moduledoc "`com.atproto.sync.*` on the PDS: repo, record and block export, blobs, listRepos, status."
  use AeroxWeb, :controller
  use AeroxWeb.Plugs.XRPCError
  import AeroxWeb.XRPC
  import Ecto.Query
  alias Aerox.ATProto.{CAR, CID}
  alias Aerox.ATProto.Repo, as: KRepo
  alias Aerox.PDS.{Accounts, Blobs, Blockstore, Records}
  alias AeroxWeb.XRPC.Error

  # Upstream assertRepoAvailability: the account itself and admins see
  # taken-down / deactivated repos; everyone else gets the named error.
  defp available!(conn, handle_or_did) do
    account =
      Accounts.get_account(handle_or_did, include_deactivated: true, include_taken_down: true) ||
        raise(
          Error.invalid_request("Could not find repo for DID: #{handle_or_did}", "RepoNotFound")
        )

    auth = conn.assigns[:auth]

    self_or_admin =
      match?(%{type: :admin}, auth) or
        match?(%{type: :access, did: did} when did == account.did, auth)

    cond do
      self_or_admin ->
        account

      account.takedown_ref ->
        raise Error.invalid_request("Repo has been takendown: #{handle_or_did}", "RepoTakendown")

      account.deactivated_at ->
        raise Error.invalid_request(
                "Repo has been deactivated: #{handle_or_did}",
                "RepoDeactivated"
              )

      true ->
        account
    end
  end

  defp car(conn, bytes) do
    conn |> put_resp_content_type("application/vnd.ipld.car", nil) |> send_resp(200, bytes)
  end

  def get_repo(conn, _) do
    params = params!(conn, "com.atproto.sync.getRepo")
    account = available!(conn, params["did"])

    root =
      Records.root(account.did) ||
        raise(Error.invalid_request("Could not find repo for DID: #{params["did"]}"))

    case KRepo.export_car(Blockstore.new(account.did), root.cid) do
      {:ok, bytes} -> car(conn, bytes)
      {:error, reason} -> {:error, Error.internal(inspect(reason))}
    end
  end

  def get_record(conn, _) do
    params = params!(conn, "com.atproto.sync.getRecord")
    account = available!(conn, params["did"])

    root =
      Records.root(account.did) ||
        raise(Error.invalid_request("Could not find repo for DID: #{params["did"]}"))

    case KRepo.record_proof_blocks(
           Blockstore.new(account.did),
           root.cid,
           params["collection"],
           params["rkey"]
         ) do
      {:ok, blocks} ->
        car(conn, CAR.encode(root.cid, blocks))

      {:error, reason} ->
        {:error,
         Error.invalid_request("Could not find record: #{inspect(reason)}", "RecordNotFound")}
    end
  end

  def get_blocks(conn, _) do
    params = params!(conn, "com.atproto.sync.getBlocks")
    account = available!(conn, params["did"])

    cids =
      Enum.map(
        params["cids"] || [],
        &(CID.parse(&1)
          |> then(fn
            {:ok, c} -> c
            _ -> raise Error.invalid_request("Invalid CID: #{&1}")
          end))
      )

    found = Aerox.ATProto.Blockstore.get_many(Blockstore.new(account.did), cids)

    case Enum.reject(cids, &Map.has_key?(found, &1)) do
      [] ->
        car(conn, CAR.encode(nil, Enum.map(cids, &{&1, found[&1]})))

      missing ->
        {:error,
         Error.invalid_request(
           "Could not find cids: #{Enum.map_join(missing, ",", &to_string/1)}"
         )}
    end
  end

  def get_latest_commit(conn, _) do
    params = params!(conn, "com.atproto.sync.getLatestCommit")
    account = available!(conn, params["did"])

    case Records.root(account.did) do
      nil ->
        {:error,
         Error.invalid_request("Could not find root for DID: #{params["did"]}", "RepoNotFound")}

      root ->
        respond(conn, %{"cid" => CID.to_string(root.cid), "rev" => root.rev})
    end
  end

  def get_repo_status(conn, _) do
    params = params!(conn, "com.atproto.sync.getRepoStatus")

    account =
      Accounts.get_account(params["did"], include_deactivated: true, include_taken_down: true) ||
        raise(
          Error.invalid_request("Could not find repo for DID: #{params["did"]}", "RepoNotFound")
        )

    {active, status} = Accounts.status(account)
    rev = if active, do: (Records.root(account.did) || %{rev: nil}).rev

    body =
      %{"did" => account.did, "active" => active, "status" => status, "rev" => rev}
      |> Enum.reject(fn {k, v} -> is_nil(v) or (k == "status" and active) end)
      |> Map.new()

    respond(conn, body)
  end

  def list_repos(conn, _) do
    params = params!(conn, "com.atproto.sync.listRepos")
    limit = params["limit"] || 500

    q =
      from(a in Aerox.PDS.Schema.Actor,
        join: r in Aerox.PDS.Schema.RepoRoot,
        on: r.did == a.did,
        order_by: [asc: a.created_at, asc: a.did],
        limit: ^limit,
        select: %{
          did: a.did,
          head: r.cid,
          rev: r.rev,
          created_at: a.created_at,
          deactivated_at: a.deactivated_at,
          takedown_ref: a.takedown_ref
        }
      )

    q =
      case params["cursor"] && String.split(params["cursor"], "::", parts: 2) do
        [ms, did] ->
          with {ms, ""} <- Integer.parse(ms), {:ok, ts} <- DateTime.from_unix(ms, :millisecond) do
            where(q, [a], a.created_at > ^ts or (a.created_at == ^ts and a.did > ^did))
          else
            _ -> raise Error.invalid_request("Malformed cursor")
          end

        _ ->
          q
      end

    rows = Aerox.PDS.Repo.all(q)

    repos =
      Enum.map(rows, fn row ->
        {active, status} = Accounts.status(row)

        %{"did" => row.did, "head" => row.head, "rev" => row.rev, "active" => active}
        |> then(&if(active, do: &1, else: Map.put(&1, "status", status)))
      end)

    cursor =
      case List.last(rows) do
        nil -> nil
        last -> "#{DateTime.to_unix(last.created_at, :millisecond)}::#{last.did}"
      end

    respond(
      conn,
      %{"repos" => repos, "cursor" => cursor}
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()
    )
  end

  def get_blob(conn, _) do
    params = params!(conn, "com.atproto.sync.getBlob")
    account = available!(conn, params["did"])

    cid =
      CID.parse(params["cid"])
      |> then(fn
        {:ok, c} -> c
        _ -> raise Error.invalid_request("Invalid CID")
      end)

    case Blobs.get(account.did, cid) do
      {:error, :not_found} ->
        {:error, Error.invalid_request("Blob not found", "BlobNotFound")}

      {:ok, %{size: size, mime_type: mime, stream: stream}} ->
        conn =
          conn
          |> put_resp_header("content-length", Integer.to_string(size))
          |> put_resp_header("x-content-type-options", "nosniff")
          |> put_resp_header("content-disposition", ~s(attachment; filename="#{params["cid"]}"))
          |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
          |> put_resp_content_type(mime || "application/octet-stream", nil)
          |> send_chunked(200)

        Enum.reduce_while(stream, conn, fn chunk, conn ->
          case chunk(conn, chunk) do
            {:ok, conn} -> {:cont, conn}
            {:error, _} -> {:halt, conn}
          end
        end)
    end
  end

  def list_blobs(conn, _) do
    params = params!(conn, "com.atproto.sync.listBlobs")
    account = available!(conn, params["did"])

    cids =
      Blobs.list(account.did,
        since: params["since"],
        limit: params["limit"],
        cursor: params["cursor"]
      )

    respond(
      conn,
      %{"cids" => cids, "cursor" => List.last(cids)}
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()
    )
  end
end
