defmodule Aerox.Labeler.Setup do
  @moduledoc """
  Makes the labeler an account (DESIGN §17.1): the only place the Labeler
  touches `Aerox.PDS` directly, so it is its own boundary. `ensure_account!/1`

  1. creates the account on our PDS through `Aerox.PDS.Signup` when the
     handle is not taken (idempotent otherwise);
  2. writes the `app.bsky.labeler.service` record `self` with the labeler's
     policies (`Aerox.Labeler.Policies`);
  3. updates the DID document through `Aerox.PDS.PlcOps.update/4` so it
     carries an `#atproto_labeler` service (`AtprotoLabeler`, the labeler's
     public URL) and an `#atproto_label` verification method for the
     labeler signing key;
  4. persists the DID and the signing key in `labeler.setting` so
     `Aerox.Labeler.Config` knows them at boot.

  The labeler signing key is the account's repo signing key, as upstream
  ozone's is (the PDS verifies the labeler's service JWTs against the
  DID document's `#atproto` key), so the same key appears under both
  `#atproto` and `#atproto_label`.
  """
  use Boundary,
    top_level?: true,
    deps: [Aerox.PDS, Aerox.Labeler, Aerox.ATProto, Aerox.Identity]

  require Logger
  alias Aerox.ATProto.Crypto
  alias Aerox.Labeler.{Config, Policies, Settings}
  alias Aerox.PDS.{Accounts, PlcOps, Records}
  alias Aerox.PDS.Records.Prepare

  @service_collection "app.bsky.labeler.service"

  @type opts :: [handle: String.t(), password: String.t(), email: String.t()]

  @doc "Runs the steps above; returns `%{did, handle, signing_key_hex, created?}`."
  @spec ensure_account!(opts) :: %{
          did: String.t(),
          handle: String.t(),
          signing_key_hex: String.t(),
          created?: boolean
        }
  def ensure_account!(opts) do
    handle = Keyword.fetch!(opts, :handle)

    {account, created?} =
      case Accounts.get_account(handle, include_deactivated: true) do
        nil ->
          {:ok, created} =
            Aerox.PDS.Signup.create(%{
              handle: handle,
              email: Keyword.get(opts, :email, "labeler@" <> Config.hostname()),
              password: Keyword.get(opts, :password) || raise("password required")
            })
            |> case do
              {:ok, c} -> {:ok, c}
              {:error, {name, msg}} -> raise "labeler signup failed: #{name}: #{msg}"
            end

          {Accounts.get_account(created.did), true}

        account ->
          {account, false}
      end

    did = account.did
    keypair = Accounts.signing_keypair(did)
    :ok = ensure_service_record(did)
    :ok = ensure_did_document(did, Crypto.did_key(keypair))

    hex = Base.encode16(keypair.private, case: :lower)
    Settings.put("did", did)
    Settings.put("signing_key_hex", hex)

    Logger.info("labeler account ready did=#{did} handle=#{handle} created=#{created?}")
    %{did: did, handle: handle, signing_key_hex: hex, created?: created?}
  end

  # Step 2: the labeler service record, written only when absent or stale.
  defp ensure_service_record(did) do
    record = Policies.service_record(Config.label_values())

    case Records.get_record(did, @service_collection, "self") do
      {:ok, %{value: existing}} ->
        if Map.delete(existing, "createdAt") == Map.delete(record, "createdAt") do
          :ok
        else
          record = Map.put(record, "createdAt", existing["createdAt"] || record["createdAt"])
          {:ok, w} = Prepare.update(did, @service_collection, "self", record)
          {:ok, _} = Records.process_writes(did, [w])
          :ok
        end

      _ ->
        {:ok, w} = Prepare.create(did, @service_collection, record, rkey: "self")
        {:ok, _} = Records.process_writes(did, [w])
        :ok
    end
  end

  # Step 3: the DID document, updated only when it lacks the service or the key.
  defp ensure_did_document("did:plc:" <> _ = did, did_key) do
    endpoint = Config.public_url()

    {:ok, last} = PlcOps.last_op(did)
    normalized = normalize(last)

    current_service = get_in(normalized, ["services", "atproto_labeler"])
    current_key = get_in(normalized, ["verificationMethods", "atproto_label"])

    if current_key == did_key and
         current_service == %{"type" => "AtprotoLabeler", "endpoint" => endpoint} do
      :ok
    else
      {:ok, _op} =
        PlcOps.update(
          did,
          fn op ->
            op
            |> put_in(["services", "atproto_labeler"], %{
              "type" => "AtprotoLabeler",
              "endpoint" => endpoint
            })
            |> put_in(["verificationMethods", "atproto_label"], did_key)
          end,
          "labeler_setup",
          "labeler"
        )

      for cache <- [Aerox.PDS.Identity, Aerox.Labeler.Identity, Aerox.AppView.Identity],
          Process.whereis(cache) != nil,
          do: Aerox.Identity.invalidate(cache, did)

      :ok
    end
  end

  defp ensure_did_document(_did_web, _did_key) do
    # a did:web labeler publishes its own document; nothing to update
    :ok
  end

  # a legacy `create` op has no `services`/`verificationMethods` maps
  defp normalize(%{"type" => "create"} = op) do
    %{
      "verificationMethods" => %{"atproto" => op["signingKey"]},
      "services" => %{
        "atproto_pds" => %{"type" => "AtprotoPersonalDataServer", "endpoint" => op["service"]}
      }
    }
  end

  defp normalize(op), do: op
end
