defmodule AeroxWeb.PDS.ServerController do
  @moduledoc "`com.atproto.server.*` (DESIGN §11.2, §18)."
  use AeroxWeb, :controller
  use AeroxWeb.Plugs.XRPCError
  import AeroxWeb.XRPC

  # DESIGN §18.2: per-route buckets beyond the global IP bucket.
  plug AeroxWeb.Plugs.RateLimit, :create_account when action == :create_account
  plug AeroxWeb.Plugs.RateLimit, :create_session when action == :create_session

  plug AeroxWeb.Plugs.RateLimit,
       :request_email_confirmation when action == :request_email_confirmation

  plug AeroxWeb.Plugs.RateLimit, :request_password_reset when action == :request_password_reset
  plug AeroxWeb.Plugs.RateLimit, :request_email_update when action == :request_email_update
  plug AeroxWeb.Plugs.RateLimit, :request_account_delete when action == :request_account_delete
  alias Aerox.PDS.{Accounts, Config, Mailer, PlcOps, Records, Sequencer, Sessions, Signup}
  alias AeroxWeb.XRPC.Error

  def health(conn, _), do: respond(conn, %{"version" => to_string(Application.spec(:aerox, :vsn))})

  def describe_server(conn, _) do
    body =
      %{
        "did" => Config.service_did(),
        "availableUserDomains" => Config.handle_domains(),
        "inviteCodeRequired" => Config.invites_required?(),
        "links" =>
          %{
            "privacyPolicy" => Config.privacy_policy_url(),
            "termsOfService" => Config.terms_of_service_url()
          }
          |> reject_nil(),
        "contact" => %{"email" => Config.contact_email()} |> reject_nil()
      }
      |> reject_nil()

    respond(conn, body)
  end

  defp reject_nil(map),
    do: map |> Enum.reject(fn {_, v} -> is_nil(v) or v == %{} end) |> Map.new()

  def create_account(conn, _) do
    input = input!(conn, "com.atproto.server.createAccount")

    params =
      %{
        handle: input["handle"],
        email: input["email"],
        password: input["password"],
        invite_code: input["inviteCode"],
        recovery_key: input["recoveryKey"],
        did: input["did"]
      }
      |> Map.reject(fn {_, v} -> is_nil(v) end)

    if input["plcOp"], do: raise(Error.invalid_request("Unsupported input: \"plcOp\""))

    case Signup.create(params) do
      {:ok, result} ->
        json(
          conn,
          %{
            "handle" => result.handle,
            "did" => result.did,
            "didDoc" => result.did_doc,
            "accessJwt" => result.access_jwt,
            "refreshJwt" => result.refresh_jwt
          }
          |> reject_nil()
        )

      {:error, {name, msg}} ->
        {:error,
         %Error{
           status: if(name == "UpstreamFailure", do: 502, else: 400),
           name: name,
           message: msg
         }}
    end
  end

  def create_session(conn, _) do
    input = input!(conn, "com.atproto.server.createSession")
    started = System.monotonic_time(:millisecond)

    result = Accounts.login(input["identifier"], input["password"])
    # upstream pads login to 350 ms so timing does not reveal which check failed
    Process.sleep(max(0, 350 - (System.monotonic_time(:millisecond) - started)))

    case result do
      {:error, :password_too_long} ->
        {:error, Error.auth_required("Password too long. Consider resetting your password.")}

      {:error, :invalid_login} ->
        {:error, Error.auth_required("Invalid identifier or password")}

      {:ok, account, app_password} ->
        soft_deleted = Accounts.soft_deleted?(account)

        if soft_deleted and input["allowTakendown"] != true do
          {:error, Error.auth_required("Account has been taken down", "AccountTakedown")}
        else
          tokens = Sessions.create_session(account.did, app_password, soft_deleted)
          respond(conn, session_body(account, tokens))
        end
    end
  end

  def refresh_session(conn, _) do
    %{did: did, token_id: token_id} = require_auth!(conn, kinds: [:refresh])

    account =
      Accounts.get_account(did, include_deactivated: true, include_taken_down: true) ||
        raise(Error.invalid_request("Could not find user info for account: #{did}"))

    if Accounts.soft_deleted?(account),
      do: raise(Error.auth_required("Account has been taken down", "AccountTakedown"))

    case Sessions.rotate(token_id) do
      nil -> {:error, Error.invalid_request("Token has been revoked", "ExpiredToken")}
      {:ok, tokens} -> respond(conn, session_body(account, tokens))
    end
  end

  def delete_session(conn, _) do
    %{token_id: token_id} = require_auth!(conn, kinds: [:refresh])
    :ok = Sessions.revoke(token_id)
    send_resp(conn, 200, "")
  end

  def get_session(conn, _) do
    # OAuth sessions see their email only with the email scope (upstream getSession)

    %{did: did} =
      require_auth!(conn, scopes: Sessions.access_standard() ++ [:signup_queued, :takendown])

    account =
      Accounts.get_account(did, include_deactivated: true) ||
        raise(Error.invalid_request("Could not find user info for account: #{did}"))

    {active, status} = Accounts.status(account)

    email_allowed? =
      case conn.assigns[:auth] do
        %{type: :oauth, permissions: perms} ->
          Aerox.Auth.Scopes.allows?(perms, :account, %{attr: "email", action: "read"})

        _ ->
          true
      end

    json(
      conn,
      %{
        "did" => did,
        "didDoc" => did_doc(did),
        "handle" => account.handle || "handle.invalid",
        "email" => if(email_allowed?, do: account.email),
        "emailConfirmed" => if(email_allowed?, do: not is_nil(account.email_confirmed_at)),
        "active" => active,
        "status" => status
      }
      |> reject_nil()
    )
  end

  defp session_body(account, tokens) do
    {active, status} = Accounts.status(account)

    %{
      "accessJwt" => tokens.access_jwt,
      "refreshJwt" => tokens.refresh_jwt,
      "did" => account.did,
      "didDoc" => did_doc(account.did),
      "handle" => account.handle || "handle.invalid",
      "email" => account.email,
      "emailConfirmed" => not is_nil(account.email_confirmed_at),
      "active" => active,
      "status" => status
    }
    |> reject_nil()
  end

  defp did_doc(did) do
    case Aerox.Identity.resolve_did(Aerox.PDS.Identity, did) do
      {:ok, doc} -> doc
      _ -> nil
    end
  end

  def get_service_auth(conn, _) do
    auth = require_auth!(conn, scopes: Sessions.access_standard() ++ [:takendown])
    params = params!(conn, "com.atproto.server.getServiceAuth")
    aud = params["aud"]
    lxm = params["lxm"]
    now = System.os_time(:second)

    cond do
      not Aerox.ATProto.Syntax.valid_did?(aud |> String.split("#") |> hd()) ->
        raise Error.invalid_request("aud must be a valid atproto DID or did#serviceId reference")

      auth.scope == :takendown and lxm != "com.atproto.server.createAccount" ->
        raise Error.invalid_request("Bad token scope", "InvalidToken")

      lxm != nil and lxm in privileged_methods() and
          auth.scope not in Sessions.access_privileged() ->
        raise Error.invalid_request(
                "insufficient access to request a service auth token for the following method: #{lxm}"
              )

      lxm != nil and lxm in protected_methods() ->
        raise Error.invalid_request(
                "cannot request a service auth token for the following protected method: #{lxm}"
              )

      true ->
        :ok
    end

    exp =
      case params["exp"] do
        nil ->
          if lxm, do: now + 60, else: now + 60

        exp when exp * 1 - now < 0 ->
          raise Error.invalid_request("expiration is in past", "BadExpiration")

        exp when exp - now > 3600 ->
          raise Error.invalid_request(
                  "cannot request a token with an expiration more than an hour in the future",
                  "BadExpiration"
                )

        exp when is_nil(lxm) and exp - now > 60 ->
          raise Error.invalid_request(
                  "cannot request a method-less token with an expiration more than a minute in the future",
                  "BadExpiration"
                )

        exp ->
          exp
      end

    keypair =
      Accounts.signing_keypair(auth.did) || raise(Error.invalid_request("Account not found"))

    token =
      Aerox.Auth.ServiceJWT.create(iss: auth.did, aud: aud, lxm: lxm, exp: exp, keypair: keypair)

    respond(conn, %{"token" => token})
  end

  defp privileged_methods,
    do:
      ~w(chat.bsky.actor.deleteAccount chat.bsky.actor.exportAccountData chat.bsky.convo.deleteMessageForSelf chat.bsky.convo.getConvo chat.bsky.convo.getConvoForMembers chat.bsky.convo.getLog chat.bsky.convo.getMessages chat.bsky.convo.leaveConvo chat.bsky.convo.listConvos chat.bsky.convo.muteConvo chat.bsky.convo.sendMessage chat.bsky.convo.sendMessageBatch chat.bsky.convo.unmuteConvo chat.bsky.convo.updateRead chat.bsky.moderation.getActorMetadata chat.bsky.moderation.getMessageContext chat.bsky.moderation.updateActorAccess)

  defp protected_methods,
    do:
      ~w(com.atproto.admin.sendEmail com.atproto.identity.requestPlcOperationSignature com.atproto.identity.signPlcOperation com.atproto.identity.updateHandle com.atproto.server.activateAccount com.atproto.server.confirmEmail com.atproto.server.createAppPassword com.atproto.server.deactivateAccount com.atproto.server.getAccountInviteCodes com.atproto.server.listAppPasswords com.atproto.server.requestAccountDelete com.atproto.server.requestEmailConfirmation com.atproto.server.requestEmailUpdate com.atproto.server.revokeAppPassword com.atproto.server.updateEmail)

  def deactivate_account(conn, _) do
    %{did: did} = require_auth!(conn, scopes: Sessions.access_full() ++ [:takendown])
    input = conn.body_params

    delete_after =
      case input["deleteAfter"] do
        nil -> nil
        str -> with {:ok, dt, _} <- DateTime.from_iso8601(str), do: dt
      end

    case Accounts.deactivate(did, delete_after) do
      :ok ->
        {_, status} =
          Accounts.status(
            Accounts.get_account(did, include_deactivated: true, include_taken_down: true)
          )

        Sequencer.sequence_account(did, status)
        send_resp(conn, 200, "")

      {:error, :not_found} ->
        {:error, Error.invalid_request("Account not found")}
    end
  end

  def activate_account(conn, _) do
    %{did: did} = require_auth!(conn, scopes: Sessions.access_full())

    account =
      Accounts.get_account(did, include_deactivated: true) ||
        raise(Error.invalid_request("user not found", "AccountNotFound"))

    with {:ok, doc} <- Aerox.Identity.resolve_did(Aerox.PDS.Identity, did, force: true),
         true <-
           Aerox.ATProto.Identity.pds_endpoint(doc) == Config.public_url() ||
             raise(
               Error.invalid_request("DID document pds endpoint does not match service endpoint")
             ),
         {:ok, key} <- Aerox.ATProto.Identity.signing_did_key(doc),
         true <-
           key == Aerox.ATProto.Crypto.did_key(Accounts.signing_keypair(did)) ||
             raise(
               Error.invalid_request(
                 "DID document signing key does not match account signing key"
               )
             ) do
      :ok = Accounts.activate(did)
      {_, status} = Accounts.status(Accounts.get_account(did))
      %{cid: cid, rev: rev} = Records.root(did)
      {:ok, bytes} = Aerox.ATProto.Blockstore.get(Aerox.PDS.Blockstore.new(did), cid)

      Sequencer.sequence_account_activation(
        did,
        account.handle || "handle.invalid",
        status,
        {cid, rev, bytes}
      )

      send_resp(conn, 200, "")
    else
      {:error, _} -> {:error, Error.invalid_request("Could not resolve DID document")}
      :error -> {:error, Error.invalid_request("DID document has no signing key")}
    end
  end

  def check_account_status(conn, _) do
    %{did: did} = require_auth!(conn)
    root = Records.root(did) || raise(Error.invalid_request("No repo root found"))
    account = Accounts.get_account(did, include_deactivated: true)

    valid_did =
      case Aerox.Identity.resolve_did(Aerox.PDS.Identity, did) do
        {:ok, doc} ->
          Aerox.ATProto.Identity.pds_endpoint(doc) == Config.public_url() and
            Aerox.ATProto.Identity.signing_did_key(doc) ==
              {:ok, Aerox.ATProto.Crypto.did_key(Accounts.signing_keypair(did))}

        _ ->
          false
      end

    respond(conn, %{
      "activated" => account != nil and is_nil(account.deactivated_at),
      "validDid" => valid_did,
      "repoCommit" => Aerox.ATProto.CID.to_string(root.cid),
      "repoRev" => root.rev,
      "repoBlocks" => Aerox.PDS.Blockstore.count(did),
      "indexedRecords" => Records.record_count(did),
      "privateStateValues" => 0,
      "expectedBlobs" => Aerox.PDS.Blobs.expected_count(did),
      "importedBlobs" => Aerox.PDS.Blobs.count(did)
    })
  end

  # ---------------------------------------------------------- app passwords

  def create_app_password(conn, _) do
    %{did: did} = require_auth!(conn, scopes: Sessions.access_full())
    input = input!(conn, "com.atproto.server.createAppPassword")

    case Accounts.create_app_password(did, input["name"], input["privileged"] || false) do
      {:ok, ap} ->
        respond(conn, %{
          "name" => ap.name,
          "password" => ap.password,
          "createdAt" => Aerox.ATProto.Syntax.format_datetime(ap.created_at),
          "privileged" => ap.privileged
        })

      {:error, :name_taken} ->
        {:error, Error.invalid_request("App password with this name already exists")}
    end
  end

  def list_app_passwords(conn, _) do
    %{did: did} = require_auth!(conn)

    respond(conn, %{
      "passwords" =>
        Enum.map(
          Accounts.list_app_passwords(did),
          &%{
            "name" => &1.name,
            "createdAt" => Aerox.ATProto.Syntax.format_datetime(&1.created_at),
            "privileged" => &1.privileged
          }
        )
    })
  end

  def revoke_app_password(conn, _) do
    %{did: did} = require_auth!(conn)
    input = input!(conn, "com.atproto.server.revokeAppPassword")
    :ok = Accounts.revoke_app_password(did, input["name"])
    send_resp(conn, 200, "")
  end

  # ------------------------------------------------------------- email flows

  def request_email_confirmation(conn, _) do
    %{did: did} = require_auth!(conn)
    account = account_with_email!(did)
    token = Accounts.create_email_token(did, "confirm_email")
    {:ok, _} = Mailer.send_token("confirm_email", account.email, token)
    send_resp(conn, 200, "")
  end

  def confirm_email(conn, _) do
    %{did: did} = require_auth!(conn)
    input = input!(conn, "com.atproto.server.confirmEmail")

    case Accounts.confirm_email(did, input["email"], input["token"]) do
      :ok ->
        send_resp(conn, 200, "")

      {:error, :invalid_email} ->
        {:error, Error.invalid_request("invalid email", "InvalidEmail")}

      {:error, :expired_token} ->
        {:error, Error.invalid_request("Token is expired", "ExpiredToken")}

      {:error, _} ->
        {:error, Error.invalid_request("Token is invalid", "InvalidToken")}
    end
  end

  def request_email_update(conn, _) do
    %{did: did} = require_auth!(conn, scopes: Sessions.access_full())
    account = account_with_email!(did)
    token_required = not is_nil(account.email_confirmed_at)

    if token_required do
      token = Accounts.create_email_token(did, "update_email")
      {:ok, _} = Mailer.send_token("update_email", account.email, token)
    end

    respond(conn, %{"tokenRequired" => token_required})
  end

  def update_email(conn, _) do
    %{did: did} = require_auth!(conn, scopes: Sessions.access_full())
    input = input!(conn, "com.atproto.server.updateEmail")
    account = account_with_email!(did)

    with :ok <-
           if(account.email_confirmed_at,
             do: token_check(did, "update_email", input["token"]),
             else: :ok
           ),
         :ok <- Accounts.update_email(did, input["email"]) do
      send_resp(conn, 200, "")
    else
      {:error, :email_taken} ->
        {:error,
         Error.invalid_request(
           "This email address is already in use, please use a different email."
         )}

      {:error, %Error{} = e} ->
        {:error, e}
    end
  end

  def request_password_reset(conn, _) do
    input = input!(conn, "com.atproto.server.requestPasswordReset")

    case Accounts.get_by_email(input["email"],
           include_deactivated: true,
           include_taken_down: true
         ) do
      %{email: email, did: did, handle: handle} when is_binary(email) ->
        token = Accounts.create_email_token(did, "reset_password")
        {:ok, _} = Mailer.send_token("reset_password", email, token, handle: handle || email)
        send_resp(conn, 200, "")

      _ ->
        {:error, Error.invalid_request("account does not have an email address")}
    end
  end

  def reset_password(conn, _) do
    input = input!(conn, "com.atproto.server.resetPassword")

    if byte_size(input["password"]) > Aerox.Auth.Scrypt.new_password_max_length(),
      do: raise(Error.invalid_request("Invalid password length."))

    case Accounts.did_for_email_token("reset_password", input["token"]) do
      nil ->
        {:error, Error.invalid_request("Token is invalid", "InvalidToken")}

      did ->
        with :ok <- token_check(did, "reset_password", input["token"]) do
          :ok = Accounts.update_password(did, input["password"])
          Accounts.assert_email_token_and_cleanup(did, "reset_password", input["token"])
          send_resp(conn, 200, "")
        end
    end
  end

  def request_account_delete(conn, _) do
    %{did: did} = require_auth!(conn, scopes: Sessions.access_full())
    account = account_with_email!(did)
    token = Accounts.create_email_token(did, "delete_account")
    {:ok, _} = Mailer.send_token("delete_account", account.email, token)
    send_resp(conn, 200, "")
  end

  def delete_account(conn, _) do
    input = input!(conn, "com.atproto.server.deleteAccount")
    did = input["did"]

    if byte_size(input["password"]) > Aerox.Auth.Scrypt.old_password_max_length(),
      do: raise(Error.auth_required("Password too long. Consider resetting your password."))

    _ =
      Accounts.get_account(did, include_deactivated: true, include_taken_down: true) ||
        raise(Error.invalid_request("account not found"))

    if not Accounts.verify_account_password(did, input["password"]),
      do: raise(Error.auth_required("Invalid did or password"))

    with :ok <- token_check(did, "delete_account", input["token"]) do
      # DESIGN §18.3: tombstone through the signer (audited), then the deleted event, then the rows and blobs
      _ = PlcOps.tombstone(did)
      Accounts.delete_account(did)
      Sequencer.sequence_account_deletion(did)
      Aerox.Blob.Store.delete_all(did)
      send_resp(conn, 200, "")
    end
  end

  defp token_check(did, purpose, token) do
    case Accounts.assert_email_token(did, purpose, token || "") do
      :ok ->
        :ok

      {:error, :expired_token} ->
        {:error, Error.invalid_request("Token is expired", "ExpiredToken")}

      {:error, _} ->
        {:error, Error.invalid_request("Token is invalid", "InvalidToken")}
    end
  end

  defp account_with_email!(did) do
    case Accounts.get_account(did, include_deactivated: true, include_taken_down: true) do
      nil -> raise Error.invalid_request("account not found")
      %{email: nil} -> raise Error.invalid_request("account does not have an email address")
      account -> account
    end
  end

  # ------------------------------------------------------------ invite codes

  def create_invite_code(conn, _) do
    require_auth!(conn, kinds: [:admin])
    input = input!(conn, "com.atproto.server.createInviteCode")
    [code] = Accounts.create_invite_codes(input["forAccount"] || "admin", 1, input["useCount"])
    respond(conn, %{"code" => code})
  end

  def get_account_invite_codes(conn, _) do
    %{did: did} = require_auth!(conn, scopes: Sessions.access_full())
    params = params!(conn, "com.atproto.server.getAccountInviteCodes")
    codes = Accounts.account_invite_codes(did)

    codes =
      if params["includeUsed"] == false,
        do: Enum.filter(codes, &(length(&1.uses) < &1.available)),
        else: codes

    respond(conn, %{"codes" => Enum.map(codes, &invite_json/1)})
  end

  defp invite_json(c) do
    %{
      "code" => c.code,
      "available" => c.available,
      "disabled" => c.disabled,
      "forAccount" => c.for_account,
      "createdBy" => c.created_by,
      "createdAt" => Aerox.ATProto.Syntax.format_datetime(c.created_at),
      "uses" =>
        Enum.map(
          c.uses,
          &%{"usedBy" => &1.used_by, "usedAt" => Aerox.ATProto.Syntax.format_datetime(&1.used_at)}
        )
    }
  end
end
