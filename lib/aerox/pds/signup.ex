defmodule Aerox.PDS.Signup do
  @moduledoc """
  Account creation as a saga (DESIGN §18.3): (1) the account and its signing
  key are committed to `aerox_pds` *deactivated* with an empty repo; (2) the
  PLC genesis op is submitted to the directory; (3) the account is activated
  and the creation events sequenced. No cross-database transaction exists
  (§4.6), and in a real deployment the directory is another operator.

  Each step is idempotent and resumable: a crash after (1) leaves a
  deactivated account that `resume/1` completes; an orphan with no PLC
  document is reaped after its `delete_after`.

  `did:plc` is minted here. A DID can also be *brought*:

  * **account migration** (Account spec, "PDS Account Migration"; upstream
    `validateInputsForLocalPds`) — the request carries a service JWT from the
    DID itself (`requester`). The account is created deactivated, with the
    key reserved for the DID by `reserveSigningKey` if there is one, and no
    PLC operation: the DID document is re-pointed afterwards and
    `activateAccount` checks it. It is not reaped while it waits.
  * a `did:web` (§14.3) whose resolved document already names this PDS, its
    handle, and a key reserved here.
  """

  require Logger
  import Ecto.Query
  alias Aerox.ATProto.Crypto
  alias Aerox.ATProto.Syntax

  alias Aerox.PDS.{
    Accounts,
    Config,
    Handle,
    PhoneVerification,
    PlcOps,
    Records,
    Repo,
    ReservedKeys,
    Sequencer,
    Sessions
  }

  alias Aerox.PDS.Schema.Actor

  @type params :: %{
          required(:handle) => String.t(),
          optional(:email) => String.t(),
          optional(:password) => String.t(),
          optional(:invite_code) => String.t(),
          optional(:recovery_key) => String.t(),
          optional(:did) => String.t(),
          optional(:requester) => String.t(),
          optional(:verification_phone) => String.t(),
          optional(:verification_code) => String.t(),
          optional(:deactivated) => boolean
        }

  @type error :: {:error, {String.t(), String.t()}}

  @doc "Runs the whole saga; returns the session and DID document."
  @spec create(params) ::
          {:ok,
           %{
             did: String.t(),
             handle: String.t(),
             access_jwt: String.t(),
             refresh_jwt: String.t(),
             did_doc: map | nil
           }}
          | error
  def create(params) do
    with {:ok, handle} <- validate_handle(params),
         :ok <- validate_email(params[:email]),
         :ok <- validate_password(params[:password]),
         :ok <- validate_invite(params[:invite_code]),
         {:ok, did, plc_op, keypair, mode} <- mint_did(params, handle),
         # a migrating account was verified where it was created
         :ok <-
           if(mode == :migration,
             do: :ok,
             else:
               PhoneVerification.verify(params[:verification_phone], params[:verification_code])
           ),
         {:ok, _account} <- register_deactivated(did, handle, keypair, params, mode),
         :ok <- publish(did, plc_op),
         {:ok, doc} <-
           activate(did, handle, mode == :migration or Map.get(params, :deactivated, false)) do
      if mode != :new, do: ReservedKeys.clear(Crypto.did_key(keypair), did)
      tokens = Sessions.create_session(did)

      {:ok,
       %{
         did: did,
         handle: handle,
         access_jwt: tokens.access_jwt,
         refresh_jwt: tokens.refresh_jwt,
         did_doc: doc
       }}
    end
  end

  defp validate_handle(%{handle: handle} = params) do
    migrating? = is_binary(params[:did]) and params[:did] == params[:requester]

    case Handle.validate(handle) do
      {:ok, h} ->
        {:ok, h}

      # a migrating account may keep a handle of its own domain (upstream
      # `normalizeAndValidateHandle` with the DID): it must resolve to that DID
      {:ok, :external, h} when migrating? ->
        if Aerox.Identity.resolve_handle(Aerox.PDS.Identity, h, force: true) ==
             {:ok, params[:did]},
           do: {:ok, h},
           else: {:error, {"InvalidHandle", "External handle did not resolve to DID"}}

      {:ok, :external, _h} ->
        {:error, {"UnsupportedDomain", "Not a supported handle domain"}}

      {:error, {:invalid_handle, msg}} ->
        {:error, {"InvalidHandle", msg}}

      {:error, {:handle_not_available, msg}} ->
        {:error, {"HandleNotAvailable", msg}}
    end
  end

  defp validate_handle(_), do: {:error, {"InvalidHandle", "Handle is required"}}

  defp validate_email(nil), do: :ok

  defp validate_email(email) do
    if Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email),
      do: :ok,
      else:
        {:error,
         {"InvalidRequest", "This email address is not supported, please use a different email."}}
  end

  defp validate_password(nil), do: :ok

  defp validate_password(pw) do
    if byte_size(pw) > Aerox.Auth.Scrypt.new_password_max_length(),
      do:
        {:error,
         {"InvalidRequest",
          "Password too long. Maximum length is #{Aerox.Auth.Scrypt.new_password_max_length()} characters."}},
      else: :ok
  end

  defp validate_invite(code) do
    cond do
      Config.invites_required?() and is_nil(code) ->
        {:error, {"InvalidInviteCode", "No invite code provided"}}

      true ->
        case Accounts.ensure_invite_available(code) do
          :ok -> :ok
          {:error, {:invite, msg}} -> {:error, {"InvalidInviteCode", msg}}
        end
    end
  end

  # Step 0: the DID and its signing key. A new did:plc is derived from the
  # signed genesis op (not yet submitted); a brought DID is either a migration
  # (authorised by the DID itself) or a did:web validated against its document.
  defp mint_did(%{did: did, requester: did} = _params, _handle) when is_binary(did) do
    if Syntax.valid_did?(did) do
      keypair = ReservedKeys.get(did) || Crypto.generate(:k256)
      {:ok, did, nil, keypair, :migration}
    else
      {:error, {"InvalidRequest", "Invalid DID: #{did}"}}
    end
  end

  defp mint_did(%{did: "did:web:" <> _ = did}, handle) do
    case Aerox.Identity.Resolver.resolve_did(did, plc_url: Config.plc_url()) do
      {:ok, doc} ->
        doc_key =
          case Aerox.ATProto.Identity.signing_did_key(doc) do
            {:ok, key} -> key
            _ -> nil
          end

        keypair = ReservedKeys.get(did) || ReservedKeys.get(doc_key)

        cond do
          Aerox.ATProto.Identity.pds_endpoint(doc) != Config.public_url() ->
            {:error,
             {"IncompatibleDidDoc", "DID document pds endpoint does not match service endpoint"}}

          Aerox.ATProto.Identity.handle(doc) != handle ->
            {:error, {"IncompatibleDidDoc", "DID document handle does not match handle"}}

          keypair == nil or doc_key != Crypto.did_key(keypair) ->
            {:error,
             {"IncompatibleDidDoc", "DID document signing key does not match reserved key"}}

          true ->
            {:ok, did, nil, keypair, :brought}
        end

      {:error, _} ->
        {:error, {"IncompatibleDidDoc", "Could not resolve DID document"}}
    end
  end

  defp mint_did(%{did: did}, _handle),
    do: {:error, {"AuthenticationRequired", "Missing auth to create account with did: #{did}"}}

  defp mint_did(params, handle) do
    keypair = Crypto.generate(:k256)

    # Reaching the signer first: `genesis_op/3` needs the rotation key's
    # `did:key` too, and building the signer is what fetches it.
    with {:ok, _signer} <- Config.fetch_signer(),
         unsigned = PlcOps.genesis_op(Crypto.did_key(keypair), handle, params[:recovery_key]),
         {:ok, did, op} <- sign_genesis(unsigned) do
      {:ok, did, op, keypair, :new}
    else
      {:error, {_, _}} = e -> e
      {:error, reason} -> signer_unavailable(reason)
    end
  end

  defp sign_genesis(unsigned) do
    case PlcOps.sign(unsigned, "pending", "signup", "pds") do
      {:ok, signed} ->
        {:ok, PlcOps.did_for_op(signed), signed}

      {:error, reason} ->
        signer_unavailable(reason)
    end
  end

  # The rotation key lives off this host (DESIGN §14.2), so signing is a call to
  # another service and it can be down. That is not the caller's fault and it is
  # worth retrying, which is what 502 tells a client; a 400 would tell it to
  # change its request instead, and a 500 tells it nothing at all.
  defp signer_unavailable(reason) do
    Logger.error("signup: rotation-key signer unavailable reason=#{inspect(reason)}")
    {:error, {"UpstreamFailure", "The signing service is unavailable"}}
  end

  # Step 1: everything local, deactivated, in one transaction.
  defp register_deactivated(did, handle, keypair, params, mode) do
    Repo.transaction(fn ->
      case Accounts.register(%{
             did: did,
             handle: handle,
             signing_key: keypair.private,
             email: params[:email],
             password: params[:password],
             invite_code: params[:invite_code],
             deactivated: true,
             # a migrating account waits for its DID document, not for PLC
             reap: mode != :migration
           }) do
        {:ok, account} ->
          {:ok, _} = Records.create_repo(did, keypair)
          account

        {:error, :handle_taken} ->
          Repo.rollback({"HandleNotAvailable", "Handle already taken: #{handle}"})

        {:error, :email_taken} ->
          Repo.rollback({"InvalidRequest", "Email already taken"})

        {:error, {:invite, msg}} ->
          Repo.rollback({"InvalidInviteCode", msg})
      end
    end)
    |> case do
      {:ok, account} -> {:ok, account}
      {:error, {name, msg}} -> {:error, {name, msg}}
    end
  end

  # Step 2: the directory. On failure the local rows are removed so the
  # handle is free again (no PLC document exists to leave behind).
  defp publish(_did, nil), do: :ok

  defp publish(did, op) do
    case PlcOps.submit(did, op) do
      :ok ->
        :ok

      {:error, reason} ->
        Accounts.delete_account(did)

        {:error,
         {"UpstreamFailure", "Could not register DID with the PLC directory: #{inspect(reason)}"}}
    end
  end

  # Step 3: resolve, activate, sequence. Also what `resume/1` runs.
  defp activate(did, handle, keep_deactivated?) do
    doc =
      case Aerox.Identity.Cache.resolve_did(Aerox.PDS.Identity, did, force: true) do
        {:ok, doc} -> doc
        _ -> nil
      end

    if keep_deactivated? do
      {:ok, doc}
    else
      :ok = Accounts.activate(did)
      %{cid: cid, rev: rev} = Records.root(did)
      {:ok, bytes} = Aerox.ATProto.Blockstore.get(Aerox.PDS.Blockstore.new(did), cid)

      commit = %{
        cid: cid,
        rev: rev,
        new_blocks: %{cid => bytes},
        relevant_blocks: %{},
        since: nil,
        prev_data: nil,
        ops: []
      }

      {:ok, _} = Sequencer.sequence_account_creation(did, handle, commit)
      {:ok, doc}
    end
  end

  @doc "Completes a signup that crashed after step 1: the PLC document exists → activate; it does not → leave for the reaper."
  @spec resume(String.t()) :: {:ok, :activated} | {:ok, :orphan} | {:error, term}
  def resume(did) do
    case Accounts.get_account(did, include_deactivated: true) do
      %{deactivated_at: at, handle: handle} when not is_nil(at) ->
        case PlcOps.resolve(did) do
          {:ok, _} ->
            {:ok, _} = activate(did, handle, false)
            {:ok, :activated}

          {:error, :not_found} ->
            {:ok, :orphan}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :not_pending}
    end
  end

  @doc "Removes deactivated accounts past `delete_after` that never got a PLC document (DESIGN §18.3 'reaped')."
  @spec reap_orphans() :: [String.t()]
  def reap_orphans do
    now = DateTime.utc_now()

    from(a in Actor, where: not is_nil(a.deactivated_at) and a.delete_after < ^now, select: a.did)
    |> Repo.all()
    |> Enum.filter(fn did -> PlcOps.resolve(did) == {:error, :not_found} end)
    |> Enum.map(fn did ->
      Accounts.delete_account(did)
      did
    end)
  end
end
