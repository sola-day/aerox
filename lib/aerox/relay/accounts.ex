defmodule Aerox.Relay.Accounts do
  @moduledoc "Account rows, host binding and status (indigo relay `account.go`)."
  import Ecto.Query
  alias Aerox.ATProto.Identity, as: DidDoc
  alias Aerox.Relay.{Config, Hosts, Repo}
  alias Aerox.Relay.Schema.{Account, AccountRepo, Host}

  def get(did), do: Repo.get_by(Account, did: did)

  def get_repo(uid), do: Repo.get(AccountRepo, uid)

  @doc "Accounts by uid after `cursor`, with their repo state (for `listRepos`)."
  def list_detailed(cursor \\ 0, limit \\ 500) do
    from(a in Account,
      left_join: r in AccountRepo,
      on: r.uid == a.uid,
      where: a.uid > ^cursor,
      order_by: [asc: a.uid],
      limit: ^limit,
      select: {a, r}
    )
    |> Repo.all()
  end

  @doc """
  Creates the account on `host` after checking the DID document places it
  there (unless `skip_account_host_check`). Past the host's account limit the
  account is created `host-throttled`.
  """
  def create_on_host(did, %Host{} = host) do
    with {:ok, doc} <- resolve(did),
         {:ok, pds_host} <- pds_hostname(doc),
         :ok <- check_host(pds_host, host.hostname) do
      status = if host.account_count >= host.account_limit, do: "host-throttled", else: "active"

      Repo.transaction(fn ->
        Hosts.increment_accounts(host.id)

        case Repo.insert(
               %Account{did: did, host_id: host.id, status: status, upstream_status: "active"},
               on_conflict: :nothing,
               conflict_target: :did
             ) do
          {:ok, %Account{uid: nil}} -> get(did)
          {:ok, acc} -> acc
          {:error, e} -> Repo.rollback(e)
        end
      end)
    end
  end

  @doc "Confirms the account is on `host`, re-resolving once if the cached document disagrees; moves it when the document says so."
  def ensure_host(%Account{host_id: host_id} = acc, %Host{id: host_id}), do: {:ok, acc}

  def ensure_host(%Account{did: did} = acc, %Host{} = host) do
    with {:ok, doc} <- resolve(did),
         {:ok, pds_host} <- pds_hostname(doc),
         {:ok, pds_host} <-
           (if pds_host == host.hostname do
              {:ok, pds_host}
            else
              Aerox.Identity.invalidate(Aerox.Relay.Identity, did)
              with {:ok, doc} <- resolve(did), do: pds_hostname(doc)
            end),
         :ok <- check_host(pds_host, host.hostname) do
      Repo.transaction(fn ->
        Hosts.increment_accounts(host.id)
        Repo.update_all(from(a in Account, where: a.uid == ^acc.uid), set: [host_id: host.id])
      end)

      {:ok, %{acc | host_id: host.id}}
    end
  end

  defp check_host(pds_host, hostname) do
    cond do
      pds_host == hostname -> :ok
      Config.skip_account_host_check?() -> :ok
      true -> {:error, {:account_host_mismatch, pds_host}}
    end
  end

  defp resolve(did) do
    case Aerox.Identity.resolve_did(Aerox.Relay.Identity, did) do
      {:ok, doc} -> {:ok, doc}
      {:error, reason} -> {:error, {:identity, reason}}
    end
  end

  defp pds_hostname(doc) do
    case DidDoc.pds_endpoint(doc) do
      nil ->
        {:error, :no_pds_endpoint}

      url ->
        case Hosts.parse_hostname(url) do
          {:ok, host, _} -> {:ok, host}
          {:error, _} -> {:error, {:invalid_pds_endpoint, url}}
        end
    end
  end

  @doc "The signing `did:key` of an account, or nil when resolution fails (upstream logs and skips the signature check)."
  def signing_key(did) do
    case Aerox.Identity.resolve_signing_key(Aerox.Relay.Identity, did, []) do
      {:ok, key} -> key
      _ -> nil
    end
  end

  @doc "The handle in the DID document, or nil."
  def document_handle(did) do
    case Aerox.Identity.resolve_did(Aerox.Relay.Identity, did) do
      {:ok, doc} -> DidDoc.handle(doc)
      _ -> nil
    end
  end

  def update_upstream_status(uid, status) do
    Repo.update_all(from(a in Account, where: a.uid == ^uid), set: [upstream_status: status])
    :ok
  end

  def update_local_status(uid, status) do
    Repo.update_all(from(a in Account, where: a.uid == ^uid), set: [status: status])
    :ok
  end

  def upsert_repo(uid, rev, commit_cid, commit_data_cid) do
    Repo.insert!(
      %AccountRepo{uid: uid, rev: rev, commit_cid: commit_cid, commit_data_cid: commit_data_cid},
      on_conflict: {:replace, [:rev, :commit_cid, :commit_data_cid]},
      conflict_target: :uid
    )

    :ok
  end
end
