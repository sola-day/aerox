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

  `did:plc` is minted here. A brought `did:web` (§14.3) is accepted when the
  resolved document already names this PDS and a reserved signing key.
  """
  import Ecto.Query
  alias Aerox.ATProto.Crypto
  alias Aerox.PDS.{Accounts, Config, Handle, PlcOps, Records, Repo, Sequencer, Sessions}
  alias Aerox.PDS.Schema.Actor

  @type params :: %{
          required(:handle) => String.t(),
          optional(:email) => String.t(),
          optional(:password) => String.t(),
          optional(:invite_code) => String.t(),
          optional(:recovery_key) => String.t(),
          optional(:did) => String.t(),
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
         keypair = Crypto.generate(:k256),
         {:ok, did, plc_op} <- mint_did(params, keypair, handle),
         {:ok, _account} <- register_deactivated(did, handle, keypair, params),
         :ok <- publish(did, plc_op),
         {:ok, doc} <- activate(did, handle, Map.get(params, :deactivated, false)) do
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

  defp validate_handle(%{handle: handle}) do
    case Handle.validate(handle) do
      {:ok, h} -> {:ok, h}
      {:ok, :external, _h} -> {:error, {"UnsupportedDomain", "Not a supported handle domain"}}
      {:error, {:invalid_handle, msg}} -> {:error, {"InvalidHandle", msg}}
      {:error, {:handle_not_available, msg}} -> {:error, {"HandleNotAvailable", msg}}
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

  # Step 0: the DID. A new did:plc is derived from the signed genesis op
  # (not yet submitted); a brought DID is validated against its document.
  defp mint_did(%{did: "did:web:" <> _ = did}, keypair, handle) do
    case Aerox.Identity.Resolver.resolve_did(did, plc_url: Config.plc_url()) do
      {:ok, doc} ->
        cond do
          Aerox.ATProto.Identity.pds_endpoint(doc) != Config.public_url() ->
            {:error,
             {"IncompatibleDidDoc", "DID document pds endpoint does not match service endpoint"}}

          Aerox.ATProto.Identity.handle(doc) != handle ->
            {:error, {"IncompatibleDidDoc", "DID document handle does not match handle"}}

          Aerox.ATProto.Identity.signing_did_key(doc) != {:ok, Crypto.did_key(keypair)} ->
            {:error,
             {"IncompatibleDidDoc", "DID document signing key does not match reserved key"}}

          true ->
            {:ok, did, nil}
        end

      {:error, _} ->
        {:error, {"IncompatibleDidDoc", "Could not resolve DID document"}}
    end
  end

  defp mint_did(%{did: _}, _keypair, _handle),
    do: {:error, {"IncompatibleDidDoc", "Only did:plc and did:web accounts are supported"}}

  defp mint_did(params, keypair, handle) do
    unsigned = PlcOps.genesis_op(Crypto.did_key(keypair), handle, params[:recovery_key])

    with {:ok, signed} <- PlcOps.sign(unsigned, "pending", "signup", "pds") do
      {:ok, PlcOps.did_for_op(signed), signed}
    end
  end

  # Step 1: everything local, deactivated, in one transaction.
  defp register_deactivated(did, handle, keypair, params) do
    Repo.transaction(fn ->
      case Accounts.register(%{
             did: did,
             handle: handle,
             signing_key: keypair.private,
             email: params[:email],
             password: params[:password],
             invite_code: params[:invite_code],
             deactivated: true
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
