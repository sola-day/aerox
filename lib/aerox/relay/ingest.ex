defmodule Aerox.Relay.Ingest do
  @moduledoc """
  Event processing for one upstream host (indigo `ingest.go` + `verify.go`,
  DESIGN §19): every `#commit` is inductively verified against the account's
  last known state (`Aerox.ATProto.Repo.verify_commit_message/2`), `#sync`
  commits are loaded and signature-checked, `#identity` handles are passed
  through only when they match the DID document, `#account` statuses are
  recorded — and each accepted event is re-sequenced on the Relay's own
  sequencer. Verification failures are returned as `{:error, reason}` and
  counted against the host by the consumer; they are never re-emitted.
  """
  require Logger
  alias Aerox.ATProto.{Bytes, CAR, CID, Repo, Syntax}
  alias Aerox.ATProto.Blockstore.Memory
  alias Aerox.Relay.{Accounts, Config, Hosts, HostChecker, Sequencer}
  alias Aerox.Relay.Schema.{Account, Host}

  @max_blocks_bytes 2_000_000
  @max_ops 200
  @future_rev_tolerance_us 5 * 60 * 1_000_000

  @type result :: :ok | :dropped | {:error, term}

  @spec process(Host.t(), String.t(), map) :: result
  def process(%Host{} = host, "#commit", body), do: commit(host, body)
  def process(%Host{} = host, "#sync", body), do: sync(host, body)
  def process(%Host{} = host, "#identity", body), do: identity(host, body)
  def process(%Host{} = host, "#account", body), do: account(host, body)
  def process(_host, "#info", _body), do: :ok
  def process(_host, type, _body), do: {:error, {:unhandled_event_type, type}}

  # ----------------------------------------------------------- pre-process

  # The account exists, is on this host, and its DID is well-formed.
  defp pre_process(host, did) do
    with :ok <- if(Syntax.valid_did?(did), do: :ok, else: {:error, :invalid_did}),
         {:ok, acc} <- get_or_create(did, host),
         {:ok, acc} <- Accounts.ensure_host(acc, host) do
      {:ok, acc}
    end
  end

  defp get_or_create(did, host) do
    case Accounts.get(did) do
      nil -> Accounts.create_on_host(did, host)
      acc -> {:ok, acc}
    end
  end

  # Drops events for inactive accounts; re-checks upstream when only the upstream status disagrees.
  defp ensure_active(%Account{} = acc, host) do
    cond do
      Account.active?(acc) ->
        {:ok, acc}

      acc.status != "active" ->
        {:inactive, acc.status}

      true ->
        case HostChecker.fetch_account_status(Hosts.http_url(host), acc.did) do
          {:ok, status} ->
            if status != acc.upstream_status, do: Accounts.update_upstream_status(acc.uid, status)
            acc = %{acc | upstream_status: status}
            if Account.active?(acc), do: {:ok, acc}, else: {:inactive, status}

          {:error, _} ->
            {:inactive, acc.upstream_status}
        end
    end
  end

  # ---------------------------------------------------------------- commit

  defp commit(host, %{"repo" => did, "rev" => rev} = body) do
    with {:ok, acc} <- pre_process(host, did),
         {:ok, acc} <- active_or_drop(acc, host),
         prev = Accounts.get_repo(acc.uid),
         :ok <- not_stale(prev, rev),
         {:ok, new_repo} <- verify_commit(body, acc, prev) do
      Accounts.upsert_repo(acc.uid, new_repo.rev, new_repo.commit_cid, new_repo.commit_data_cid)
      emit(did, "#commit", body)
    end
  end

  defp commit(_host, _), do: {:error, :invalid_commit_event}

  defp active_or_drop(acc, host) do
    case ensure_active(acc, host) do
      {:ok, acc} -> {:ok, acc}
      {:inactive, status} -> {:dropped, {:inactive_account, status}}
    end
  end

  # fast check for an old rev (re-checked in strict verification)
  defp not_stale(%{rev: prev_rev}, rev)
       when is_binary(prev_rev) and prev_rev != "" and rev <= prev_rev,
       do: {:dropped, {:old_rev, rev, prev_rev}}

  defp not_stale(_, _), do: :ok

  defp verify_commit(%{"blocks" => %Bytes{data: car}, "ops" => ops} = body, acc, prev) do
    with :ok <-
           if(byte_size(car) <= @max_blocks_bytes, do: :ok, else: {:error, :blocks_too_large}),
         :ok <-
           if(is_list(ops) and length(ops) <= @max_ops, do: :ok, else: {:error, :too_many_ops}),
         {:ok, root, blocks} <- CAR.decode_with_root(car),
         bs = Memory.new(blocks),
         {:ok, repo} <- Repo.load(bs, root),
         :ok <- verify_commit_object(repo.commit, acc.did),
         :ok <- if(repo.commit["rev"] == body["rev"], do: :ok, else: {:error, :rev_mismatch}),
         :ok <- strict(body, repo, prev, acc) do
      {:ok,
       %{
         rev: repo.commit["rev"],
         commit_cid: CID.to_string(root),
         commit_data_cid: CID.to_string(repo.commit["data"])
       }}
    end
  end

  defp verify_commit(_, _, _), do: {:error, :invalid_commit_event}

  # Field syntax, future rev, and the signature when the identity resolves.
  defp verify_commit_object(commit, did) do
    with :ok <- if(commit["did"] == did, do: :ok, else: {:error, :did_mismatch}),
         :ok <- if(Syntax.valid_tid?(commit["rev"]), do: :ok, else: {:error, :invalid_rev}),
         :ok <- not_future(commit["rev"]) do
      case Accounts.signing_key(did) do
        nil ->
          Logger.warning(
            "relay: skipping commit signature validation, identity unavailable did=#{did}"
          )

          :ok

        key ->
          if Repo.verify_commit_sig(commit, key), do: :ok, else: {:error, :bad_signature}
      end
    end
  end

  defp not_future(rev) do
    now = System.os_time(:microsecond)

    if Aerox.ATProto.TID.timestamp(rev) > now + @future_rev_tolerance_us,
      do: {:error, :future_rev},
      else: :ok
  end

  # indigo VerifyCommitMessageStrict; failures are warnings in lenient mode.
  defp strict(body, repo, prev, acc) do
    case do_strict(body, repo, prev, acc) do
      :ok ->
        :ok

      {:error, reason} = e ->
        if Config.lenient_sync_validation?() do
          Logger.warning(
            "relay: allowing commit that failed strict validation did=#{acc.did} reason=#{inspect(reason)}"
          )

          :ok
        else
          e
        end
    end
  end

  # `tooBig` is deprecated and, per the Sync spec, ignored by consumers: a commit
  # carrying it is verified like any other, and one whose blocks really are
  # truncated fails MST inversion below. (indigo rejects the flag outright.)
  defp do_strict(body, _repo, prev, acc) do
    cond do
      body["rebase"] == true ->
        {:error, :rebase_flag}

      not Syntax.valid_datetime?(body["time"]) ->
        {:error, :invalid_time}

      prev == nil and body["prevData"] == nil ->
        :ok

      body["prevData"] == nil ->
        {:error, :missing_prev_data}

      prev != nil and body["rev"] <= prev.rev ->
        {:error, {:rev_out_of_order, body["rev"], prev.rev}}

      true ->
        if prev && CID.to_string(body["prevData"]) != prev.commit_data_cid,
          do: Logger.warning("relay: commit prevData mismatch did=#{acc.did}")

        # MST inversion: a failure is logged, not fatal (as upstream)
        case Repo.verify_commit_message(body) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "relay: failed to invert commit MST did=#{acc.did} reason=#{inspect(reason)}"
            )

            :ok
        end
    end
  end

  # ------------------------------------------------------------------ sync

  defp sync(host, %{"did" => did, "rev" => rev, "blocks" => %Bytes{data: car}} = body) do
    with {:ok, acc} <- pre_process(host, did),
         {:ok, acc} <- active_or_drop(acc, host),
         :ok <-
           if(byte_size(car) <= @max_blocks_bytes, do: :ok, else: {:error, :blocks_too_large}),
         {:ok, root, blocks} <- CAR.decode_with_root(car),
         {:ok, repo} <- Repo.load(Memory.new(blocks), root),
         :ok <- verify_commit_object(repo.commit, did),
         :ok <- if(repo.commit["rev"] == rev, do: :ok, else: {:error, :rev_mismatch}) do
      Accounts.upsert_repo(acc.uid, rev, CID.to_string(root), CID.to_string(repo.commit["data"]))
      emit(did, "#sync", body)
    end
  end

  defp sync(_host, _), do: {:error, :invalid_sync_event}

  # -------------------------------------------------------------- identity

  defp identity(host, %{"did" => did} = body) do
    if not Syntax.valid_did?(did) do
      {:error, :invalid_did}
    else
      Aerox.Identity.invalidate(Aerox.Relay.Identity, did)

      handle =
        case pre_process(host, did) do
          {:ok, _} ->
            case {body["handle"], Accounts.document_handle(did)} do
              {h, h} when is_binary(h) -> h
              _ -> nil
            end

          _ ->
            nil
        end

      out = %{"did" => did, "time" => body["time"]}
      out = if handle, do: Map.put(out, "handle", handle), else: out
      emit(did, "#identity", out)
    end
  end

  defp identity(_, _), do: {:error, :invalid_identity_event}

  # --------------------------------------------------------------- account

  defp account(host, %{"did" => did, "active" => active} = body) when is_boolean(active) do
    with {:ok, acc} <- pre_process(host, did) do
      new_status =
        cond do
          active -> "active"
          is_binary(body["status"]) -> body["status"]
          true -> "inactive"
        end

      if new_status != acc.upstream_status,
        do: Accounts.update_upstream_status(acc.uid, new_status)

      acc = %{acc | upstream_status: new_status}

      out = %{"did" => did, "active" => Account.active?(acc), "time" => body["time"]}
      out = if s = Account.status_field(acc), do: Map.put(out, "status", s), else: out
      emit(did, "#account", out)
    end
  end

  defp account(_, _), do: {:error, :invalid_account_event}

  defp emit(did, type, body) do
    case Sequencer.emit(did, type, body) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:sequencer, reason}}
    end
  end
end
