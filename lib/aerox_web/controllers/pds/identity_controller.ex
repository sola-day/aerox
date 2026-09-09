defmodule AeroxWeb.PDS.IdentityController do
  @moduledoc "`com.atproto.identity.*` on the PDS (DESIGN §14, §20.1)."
  use AeroxWeb, :controller
  use AeroxWeb.Plugs.XRPCError
  import AeroxWeb.XRPC

  plug AeroxWeb.Plugs.RateLimit, :update_handle when action == :update_handle

  plug AeroxWeb.Plugs.RateLimit,
       :request_plc_operation_signature when action == :request_plc_operation_signature

  alias Aerox.ATProto.Crypto
  alias Aerox.PDS.{Accounts, Config, Handle, Mailer, PlcOps, Sequencer, Sessions}
  alias AeroxWeb.XRPC.Error

  def resolve_handle(conn, _) do
    params = params!(conn, "com.atproto.identity.resolveHandle")

    handle =
      case Handle.normalize(params["handle"]) do
        {:ok, h} -> h
        {:error, {_, msg}} -> raise Error.invalid_request(msg, "InvalidHandle")
      end

    case Accounts.get_account(handle) do
      %{did: did} ->
        respond(conn, %{"did" => did})

      nil ->
        if Handle.service_domain?(handle) do
          {:error, Error.invalid_request("Unable to resolve handle")}
        else
          case Aerox.Identity.resolve_handle(Aerox.PDS.Identity, handle) do
            {:ok, did} -> respond(conn, %{"did" => did})
            _ -> {:error, Error.invalid_request("Unable to resolve handle")}
          end
        end
    end
  end

  def update_handle(conn, _) do
    %{did: did} = require_auth!(conn)
    input = input!(conn, "com.atproto.identity.updateHandle")

    account =
      Accounts.get_account(did, include_deactivated: true) ||
        raise(Error.invalid_request("Account not found"))

    handle =
      case Handle.validate(input["handle"]) do
        {:ok, h} ->
          h

        {:ok, :external, h} ->
          case Aerox.Identity.resolve_handle(Aerox.PDS.Identity, h, force: true) do
            {:ok, ^did} -> h
            _ -> raise Error.invalid_request("External handle did not resolve to DID")
          end

        {:error, {:invalid_handle, msg}} ->
          raise Error.invalid_request(msg, "InvalidHandle")

        {:error, {:handle_not_available, msg}} ->
          raise Error.invalid_request(msg, "HandleNotAvailable")
      end

    case Accounts.get_account(handle, include_deactivated: true, include_taken_down: true) do
      %{did: other} when other != did ->
        raise Error.invalid_request("Handle already taken: #{handle}", "HandleNotAvailable")

      _ ->
        :ok
    end

    if String.starts_with?(did, "did:plc:") do
      case PlcOps.update_handle(did, handle, did) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          raise Error.upstream_failure(
                  "Could not update handle at the PLC directory: #{inspect(reason)}"
                )
      end
    else
      case Aerox.Identity.resolve_did(Aerox.PDS.Identity, did, force: true) do
        {:ok, doc} ->
          if Aerox.ATProto.Identity.handle(doc) != handle,
            do: raise(Error.invalid_request("DID is not properly configured for handle"))

        _ ->
          raise Error.invalid_request("Could not resolve DID")
      end
    end

    :ok = Accounts.update_handle(did, handle)
    Aerox.Identity.invalidate(Aerox.PDS.Identity, did)
    Sequencer.sequence_identity(did, handle)
    _ = account
    send_resp(conn, 200, "")
  end

  def get_recommended_did_credentials(conn, _) do
    %{did: did} = require_auth!(conn)
    keypair = Accounts.signing_keypair(did) || raise(Error.invalid_request("Account not found"))
    account = Accounts.get_account(did, include_deactivated: true)

    respond(
      conn,
      %{
        "alsoKnownAs" => if(account && account.handle, do: ["at://" <> account.handle]),
        "verificationMethods" => %{"atproto" => Crypto.did_key(keypair)},
        "rotationKeys" => PlcOps.rotation_keys(),
        "services" => %{
          "atproto_pds" => %{
            "type" => "AtprotoPersonalDataServer",
            "endpoint" => Config.public_url()
          }
        }
      }
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()
    )
  end

  def request_plc_operation_signature(conn, _) do
    %{did: did} = require_auth!(conn, scopes: Sessions.access_full() ++ [:takendown])

    case Accounts.get_account(did, include_deactivated: true, include_taken_down: true) do
      nil ->
        {:error, Error.invalid_request("account not found")}

      %{email: nil} ->
        {:error, Error.invalid_request("account does not have an email address")}

      %{email: email} ->
        token = Accounts.create_email_token(did, "plc_operation")
        {:ok, _} = Mailer.send_token("plc_operation", email, token)
        send_resp(conn, 200, "")
    end
  end

  def sign_plc_operation(conn, _) do
    %{did: did} = require_auth!(conn, scopes: Sessions.access_full() ++ [:takendown])
    input = conn.body_params

    token =
      input["token"] ||
        raise(Error.invalid_request("email confirmation token required to sign PLC operations"))

    case Accounts.assert_email_token_and_cleanup(did, "plc_operation", token) do
      :ok -> :ok
      {:error, :expired_token} -> raise Error.invalid_request("Token is expired", "ExpiredToken")
      {:error, _} -> raise Error.invalid_request("Token is invalid", "InvalidToken")
    end

    # signed but NOT submitted: the client submits it (upstream semantics)
    with {:ok, last} when is_map(last) <- PlcOps.last_op(did),
         :ok <- if(last["type"] == "plc_tombstone", do: :tombstoned, else: :ok),
         normalized = last |> Map.delete("sig"),
         unsigned =
           normalized
           |> Map.put("rotationKeys", input["rotationKeys"] || normalized["rotationKeys"])
           |> Map.put("alsoKnownAs", input["alsoKnownAs"] || normalized["alsoKnownAs"])
           |> Map.put(
             "verificationMethods",
             input["verificationMethods"] || normalized["verificationMethods"]
           )
           |> Map.put("services", input["services"] || normalized["services"])
           |> Map.put("prev", PlcOps.cid(last)),
         {:ok, signed} <- PlcOps.sign(unsigned, did, "sign_plc_operation", did) do
      respond(conn, %{"operation" => signed})
    else
      {:ok, nil} -> {:error, Error.invalid_request("DID not found at the directory")}
      :tombstoned -> {:error, Error.invalid_request("Did is tombstoned")}
      {:error, reason} -> {:error, Error.upstream_failure(inspect(reason))}
    end
  end

  def submit_plc_operation(conn, _) do
    %{did: did} = require_auth!(conn)
    op = conn.body_params["operation"] || raise(Error.invalid_request("Invalid operation"))
    keypair = Accounts.signing_keypair(did) || raise(Error.invalid_request("Account not found"))
    account = Accounts.get_account(did, include_deactivated: true)

    cond do
      op["type"] != "plc_operation" ->
        raise Error.invalid_request("Invalid operation")

      PlcOps.rotation_did_key() not in (op["rotationKeys"] || []) ->
        raise Error.invalid_request("Rotation keys do not include server's rotation key")

      get_in(op, ["services", "atproto_pds", "type"]) != "AtprotoPersonalDataServer" ->
        raise Error.invalid_request("Incorrect type on atproto_pds service")

      get_in(op, ["services", "atproto_pds", "endpoint"]) != Config.public_url() ->
        raise Error.invalid_request("Incorrect endpoint on atproto_pds service")

      get_in(op, ["verificationMethods", "atproto"]) != Crypto.did_key(keypair) ->
        raise Error.invalid_request("Incorrect signing key")

      account && account.handle &&
          List.first(op["alsoKnownAs"] || []) != "at://" <> account.handle ->
        raise Error.invalid_request("Incorrect handle in alsoKnownAs")

      true ->
        :ok
    end

    case PlcOps.submit(did, op) do
      :ok ->
        Sequencer.sequence_identity(did, nil)
        Aerox.Identity.invalidate(Aerox.PDS.Identity, did)
        send_resp(conn, 200, "")

      {:error, reason} ->
        {:error,
         Error.upstream_failure("PLC directory rejected the operation: #{inspect(reason)}")}
    end
  end
end
