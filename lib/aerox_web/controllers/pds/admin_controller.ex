defmodule AeroxWeb.PDS.AdminController do
  @moduledoc "`com.atproto.admin.*`, the subset `pdsadmin` and DESIGN §17 need; HTTP Basic admin or a moderation service JWT."
  use AeroxWeb, :controller
  use AeroxWeb.Plugs.XRPCError
  import AeroxWeb.XRPC
  alias Aerox.ATProto.{CID, Syntax}
  alias Aerox.PDS.{Accounts, Blobs, Config, Records, Sequencer, Sessions}
  alias AeroxWeb.XRPC.Error

  defp admin!(conn) do
    case conn.assigns[:auth] do
      %{type: :admin} = a ->
        a

      %{type: :service, did: did} = a ->
        if did == Config.get(:mod_service_did),
          do: a,
          else: raise(Error.auth_required("Untrusted issuer", "UntrustedIss"))

      _ ->
        raise Error.auth_required()
    end
  end

  def get_account_info(conn, _) do
    admin!(conn)
    params = params!(conn, "com.atproto.admin.getAccountInfo")

    account =
      Accounts.get_account(params["did"], include_deactivated: true, include_taken_down: true) ||
        raise(Error.invalid_request("Account not found", "AccountNotFound"))

    respond(conn, account_view(account))
  end

  def get_account_infos(conn, _) do
    admin!(conn)
    params = params!(conn, "com.atproto.admin.getAccountInfos")

    infos =
      Accounts.get_accounts(params["dids"] || [],
        include_deactivated: true,
        include_taken_down: true
      )
      |> Map.values()
      |> Enum.map(&account_view/1)

    respond(conn, %{"infos" => infos})
  end

  defp account_view(a) do
    %{
      "did" => a.did,
      "handle" => a.handle || "handle.invalid",
      "email" => a.email,
      "indexedAt" => Syntax.format_datetime(a.created_at),
      "emailConfirmedAt" => a.email_confirmed_at && Syntax.format_datetime(a.email_confirmed_at),
      "invitesDisabled" => a.invites_disabled,
      "deactivatedAt" => a.deactivated_at && Syntax.format_datetime(a.deactivated_at)
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  def get_subject_status(conn, _) do
    admin!(conn)
    params = params!(conn, "com.atproto.admin.getSubjectStatus")

    cond do
      params["did"] ->
        account =
          Accounts.get_account(params["did"], include_deactivated: true, include_taken_down: true) ||
            raise(Error.invalid_request("Account not found", "AccountNotFound"))

        respond(conn, %{
          "subject" => %{"$type" => "com.atproto.admin.defs#repoRef", "did" => account.did},
          "takedown" => status_attr(account.takedown_ref),
          "deactivated" => %{"applied" => not is_nil(account.deactivated_at)}
        })

      params["uri"] ->
        {:ok, %{authority: did, collection: c, rkey: r}} = Syntax.parse_at_uri(params["uri"])

        {:ok, rec} =
          Records.get_record(did, c, r, include_taken_down: true)
          |> then(fn
            {:ok, r} -> {:ok, r}
            _ -> raise Error.invalid_request("Record not found", "RecordNotFound")
          end)

        respond(conn, %{
          "subject" => %{
            "$type" => "com.atproto.repo.strongRef",
            "uri" => rec.uri,
            "cid" => rec.cid
          },
          "takedown" => status_attr(rec.takedown_ref)
        })

      true ->
        raise Error.invalid_request("No provided subject")
    end
  end

  defp status_attr(nil), do: %{"applied" => false}
  defp status_attr(ref), do: %{"applied" => true, "ref" => ref}

  def update_subject_status(conn, _) do
    admin!(conn)
    input = conn.body_params
    subject = input["subject"] || raise(Error.invalid_request("Invalid subject"))
    takedown = input["takedown"]
    deactivated = input["deactivated"]

    ref = fn t ->
      if t["applied"], do: t["ref"] || Syntax.format_datetime(DateTime.utc_now()), else: nil
    end

    case subject["$type"] do
      "com.atproto.admin.defs#repoRef" ->
        did = subject["did"]

        if takedown do
          :ok = Accounts.set_takedown(did, ref.(takedown))

          {_, status} =
            Accounts.status(
              Accounts.get_account(did, include_deactivated: true, include_taken_down: true)
            )

          Sequencer.sequence_account(did, status)
        end

        if deactivated do
          if deactivated["applied"], do: Accounts.deactivate(did), else: Accounts.activate(did)

          {_, status} =
            Accounts.status(
              Accounts.get_account(did, include_deactivated: true, include_taken_down: true)
            )

          Sequencer.sequence_account(did, status)
        end

      "com.atproto.repo.strongRef" ->
        {:ok, %{authority: did}} = Syntax.parse_at_uri(subject["uri"])
        if takedown, do: Records.update_record_takedown(did, subject["uri"], ref.(takedown))

      "com.atproto.admin.defs#repoBlobRef" ->
        if takedown,
          do: Blobs.set_takedown(subject["did"], CID.parse!(subject["cid"]), ref.(takedown))

      _ ->
        raise Error.invalid_request("Invalid subject")
    end

    respond(
      conn,
      %{"subject" => subject, "takedown" => takedown, "deactivated" => deactivated}
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()
    )
  end

  def update_account_email(conn, _) do
    admin!(conn)
    input = conn.body_params

    did =
      Accounts.did_for_actor(input["account"],
        include_deactivated: true,
        include_taken_down: true
      ) || raise(Error.invalid_request("Account not found"))

    case Accounts.update_email(did, input["email"]) do
      :ok -> send_resp(conn, 200, "")
      {:error, :email_taken} -> {:error, Error.invalid_request("Email already in use")}
    end
  end

  def update_account_handle(conn, _) do
    admin!(conn)
    input = conn.body_params
    did = input["did"]

    handle =
      case Aerox.PDS.Handle.validate(input["handle"], allow_reserved: true) do
        {:ok, h} -> h
        {:ok, :external, h} -> h
        {:error, {_, msg}} -> raise Error.invalid_request(msg, "InvalidHandle")
      end

    if String.starts_with?(did, "did:plc:"),
      do: {:ok, _} = Aerox.PDS.PlcOps.update_handle(did, handle, "admin")

    :ok = Accounts.update_handle(did, handle)
    Aerox.Identity.invalidate(Aerox.PDS.Identity, did)
    Sequencer.sequence_identity(did, handle)
    send_resp(conn, 200, "")
  end

  def update_account_password(conn, _) do
    admin!(conn)
    input = conn.body_params
    :ok = Accounts.update_password(input["did"], input["password"])
    send_resp(conn, 200, "")
  end

  def delete_account(conn, _) do
    admin!(conn)
    did = conn.body_params["did"]

    _ =
      Accounts.get_account(did, include_deactivated: true, include_taken_down: true) ||
        raise(Error.invalid_request("Account not found"))

    Accounts.delete_account(did)
    Sequencer.sequence_account_deletion(did)
    Aerox.Blob.Store.delete_all(did)
    send_resp(conn, 200, "")
  end

  def send_email(conn, _) do
    admin!(conn)
    input = conn.body_params

    account =
      Accounts.get_account(input["recipientDid"],
        include_deactivated: true,
        include_taken_down: true
      ) || raise(Error.invalid_request("Recipient not found"))

    if is_nil(account.email),
      do: raise(Error.invalid_request("account does not have an email address"))

    case Aerox.PDS.Mailer.send_plain(
           account.email,
           input["subject"] || "Message via your PDS",
           input["content"]
         ) do
      {:ok, _} -> respond(conn, %{"sent" => true})
      {:error, _} -> respond(conn, %{"sent" => false})
    end
  end

  def get_invite_codes(conn, _) do
    admin!(conn)
    respond(conn, %{"codes" => []})
  end

  def disable_invite_codes(conn, _) do
    admin!(conn)
    codes = conn.body_params["codes"] || []
    import Ecto.Query

    Aerox.PDS.Repo.update_all(from(i in Aerox.PDS.Schema.InviteCode, where: i.code in ^codes),
      set: [disabled: true]
    )

    send_resp(conn, 200, "")
  end

  def disable_account_invites(conn, _), do: set_invites_disabled(conn, true)
  def enable_account_invites(conn, _), do: set_invites_disabled(conn, false)

  defp set_invites_disabled(conn, disabled) do
    admin!(conn)
    import Ecto.Query

    Aerox.PDS.Repo.update_all(
      from(a in Aerox.PDS.Schema.Account, where: a.did == ^conn.body_params["account"]),
      set: [invites_disabled: disabled]
    )

    send_resp(conn, 200, "")
  end

  # Not admin, but lives beside them: the moderation report intake is proxied to the labeler (M8).
  def create_report(conn, _) do
    _ = require_auth!(conn, scopes: Sessions.access_standard())
    {:error, Error.not_implemented("Moderation reports are handled by the labeler service (M8)")}
  end
end
