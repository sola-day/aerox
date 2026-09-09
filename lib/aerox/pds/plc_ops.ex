defmodule Aerox.PDS.PlcOps do
  @moduledoc """
  THE ONLY call site of `Aerox.Crypto.Signer.sign/2` for PLC operations
  (DESIGN §14.2 point 5): genesis operations at signup, user-requested
  updates (`signPlcOperation`, email-token gated by the caller), handle
  updates, and tombstones on failed signups. Every signature is recorded in
  `plc_op_audit` before it leaves the process, and every submission checks
  the operation-count invariant (point 6): the target DID's log must grow
  by exactly one.

  The directory is reached over `Aerox.Identity.HTTP`; the PDS never touches
  `Aerox.PLC` directly (STRUCTURE §6).
  """
  alias Aerox.ATProto.CID
  alias Aerox.Crypto.Signer
  alias Aerox.Identity.HTTP
  alias Aerox.PDS.{Config, Repo}
  alias Aerox.PDS.Schema.PlcOpAudit

  # `Aerox.PLC.Operations` is pure and belongs to the directory; the PDS
  # re-implements the few pure helpers it needs rather than depend on it.
  @type op :: map

  @doc "The instance rotation key's did:key."
  def rotation_did_key, do: Signer.did_key(Config.signer())

  @doc "Rotation keys for new accounts (DESIGN §14.2 point 3): [user recovery?, instance recovery?, instance rotation]."
  @spec rotation_keys(String.t() | nil) :: [String.t()]
  def rotation_keys(user_recovery_key \\ nil) do
    Enum.reject([user_recovery_key, Config.recovery_did_key(), rotation_did_key()], &is_nil/1)
  end

  @doc "The unsigned genesis operation for a new account."
  @spec genesis_op(String.t(), String.t(), String.t() | nil) :: op
  def genesis_op(signing_did_key, handle, user_recovery_key \\ nil) do
    %{
      "type" => "plc_operation",
      "verificationMethods" => %{"atproto" => signing_did_key},
      "rotationKeys" => rotation_keys(user_recovery_key),
      "alsoKnownAs" => ["at://" <> handle],
      "services" => %{
        "atproto_pds" => %{
          "type" => "AtprotoPersonalDataServer",
          "endpoint" => Config.public_url()
        }
      },
      "prev" => nil
    }
  end

  @doc "Signs an unsigned op with the instance rotation key and audits it. `purpose` and `actor` go to the audit row."
  @spec sign(op, String.t(), String.t(), String.t()) :: {:ok, op} | {:error, term}
  def sign(unsigned, did, purpose, actor) do
    unsigned = Map.delete(unsigned, "sig")
    bytes = Aerox.ATProto.DagCBOR.encode(unsigned)

    with {:ok, sig} <- Signer.sign(Config.signer(), bytes) do
      signed = Map.put(unsigned, "sig", Base.url_encode64(sig, padding: false))

      Repo.insert!(%PlcOpAudit{
        did: did,
        cid: CID.to_string(CID.for_cbor(Aerox.ATProto.DagCBOR.encode(signed))),
        purpose: purpose,
        actor: actor,
        inserted_at: DateTime.utc_now()
      })

      {:ok, signed}
    end
  end

  @doc "`did:plc:` derived from a signed genesis op."
  @spec did_for_op(op) :: String.t()
  def did_for_op(op) do
    hash = :crypto.hash(:sha256, Aerox.ATProto.DagCBOR.encode(op))
    "did:plc:" <> (hash |> Base.encode32(case: :lower, padding: false) |> binary_part(0, 24))
  end

  @doc "The op's CID string."
  def cid(op), do: CID.to_string(CID.for_cbor(Aerox.ATProto.DagCBOR.encode(op)))

  # ------------------------------------------------------------ directory

  defp base, do: String.trim_trailing(Config.plc_url(), "/")

  defp http_opts,
    do:
      Keyword.merge(
        [timeout: 10_000, allow_private: true],
        Application.get_env(:aerox, __MODULE__, [])[:http] || []
      )

  @doc "The DID's audit log at the directory (`[]` for an unknown DID)."
  @spec audit_log(String.t()) :: {:ok, [map]} | {:error, term}
  def audit_log(did) do
    case HTTP.get("#{base()}/#{did}/log/audit", http_opts()) do
      {:ok, 200, _, body} -> Jason.decode(body)
      {:ok, 404, _, _} -> {:ok, []}
      {:ok, status, _, body} -> {:error, {:plc_status, status, body}}
      {:error, _} = e -> e
    end
  end

  @doc "The last active op at the directory, or nil."
  @spec last_op(String.t()) :: {:ok, map | nil} | {:error, term}
  def last_op(did) do
    case HTTP.get("#{base()}/#{did}/log/last", http_opts()) do
      {:ok, 200, _, body} -> Jason.decode(body)
      {:ok, 404, _, _} -> {:ok, nil}
      {:ok, status, _, body} -> {:error, {:plc_status, status, body}}
      {:error, _} = e -> e
    end
  end

  @doc "The DID document at the directory."
  @spec resolve(String.t()) :: {:ok, map} | {:error, :not_found | term}
  def resolve(did) do
    case HTTP.get("#{base()}/#{did}", http_opts()) do
      {:ok, 200, _, body} -> Jason.decode(body)
      {:ok, 404, _, _} -> {:error, :not_found}
      {:ok, status, _, body} -> {:error, {:plc_status, status, body}}
      {:error, _} = e -> e
    end
  end

  @doc """
  Submits a signed operation, asserting the count invariant: the DID's log
  is one entry longer afterwards and its last entry is this op.
  """
  @spec submit(String.t(), op) :: :ok | {:error, term}
  def submit(did, op) do
    with {:ok, before} <- audit_log(did),
         :ok <- post(did, op),
         {:ok, after_} <- audit_log(did) do
      expected = cid(op)

      cond do
        length(after_) != length(before) + 1 ->
          {:error, {:plc_op_count_invariant, length(before), length(after_)}}

        List.last(after_)["cid"] != expected ->
          {:error, {:plc_op_count_invariant, :unexpected_last_op, List.last(after_)["cid"]}}

        true ->
          :ok
      end
    end
  end

  defp post(did, op) do
    case HTTP.post(
           "#{base()}/#{did}",
           op,
           Keyword.put(http_opts(), :headers, [{"content-type", "application/json"}])
         ) do
      {:ok, 200, _, _} -> :ok
      {:ok, status, _, body} -> {:error, {:plc_rejected, status, body}}
      {:error, _} = e -> e
    end
  end

  @doc "Signs and submits a genesis op; returns the new DID."
  @spec create_did(String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t(), op} | {:error, term}
  def create_did(signing_did_key, handle, user_recovery_key \\ nil) do
    unsigned = genesis_op(signing_did_key, handle, user_recovery_key)

    with {:ok, signed} <- sign(unsigned, "pending", "signup", "pds"),
         did = did_for_op(signed),
         :ok <- submit(did, signed) do
      {:ok, did, signed}
    end
  end

  @doc "Signs and submits an update built from the last op by `fun` (a normalised op without sig → new op fields)."
  @spec update(String.t(), (map -> map), String.t(), String.t()) :: {:ok, op} | {:error, term}
  def update(did, fun, purpose, actor) do
    with {:ok, last} when is_map(last) <- last_op(did),
         :ok <- if(last["type"] == "plc_tombstone", do: {:error, :tombstoned}, else: :ok),
         normalized = normalize(last),
         unsigned = normalized |> Map.delete("sig") |> fun.() |> Map.put("prev", cid(last)),
         {:ok, signed} <- sign(unsigned, did, purpose, actor),
         :ok <- submit(did, signed) do
      {:ok, signed}
    else
      {:ok, nil} -> {:error, :not_found}
      e -> e
    end
  end

  @doc "Handle update: replaces (or prepends) the `at://` alias."
  @spec update_handle(String.t(), String.t(), String.t()) :: {:ok, op} | {:error, term}
  def update_handle(did, handle, actor) do
    update(
      did,
      fn op ->
        formatted = "at://" <> handle
        akas = op["alsoKnownAs"] || []

        akas =
          case Enum.find_index(akas, &String.starts_with?(&1, "at://")) do
            nil -> [formatted | akas]
            i -> List.replace_at(akas, i, formatted)
          end

        Map.put(op, "alsoKnownAs", akas)
      end,
      "update_handle",
      actor
    )
  end

  @doc "Tombstones a DID (failed signup cleanup)."
  @spec tombstone(String.t()) :: :ok | {:error, term}
  def tombstone(did) do
    with {:ok, last} when is_map(last) <- last_op(did),
         {:ok, signed} <-
           sign(%{"type" => "plc_tombstone", "prev" => cid(last)}, did, "tombstone", "pds"),
         :ok <- submit(did, signed) do
      :ok
    else
      {:ok, nil} -> {:error, :not_found}
      e -> e
    end
  end

  defp normalize(%{"type" => "create"} = op) do
    %{
      "type" => "plc_operation",
      "verificationMethods" => %{"atproto" => op["signingKey"]},
      "rotationKeys" => [op["recoveryKey"], op["signingKey"]],
      "alsoKnownAs" => ["at://" <> String.replace_prefix(op["handle"], "at://", "")],
      "services" => %{
        "atproto_pds" => %{"type" => "AtprotoPersonalDataServer", "endpoint" => op["service"]}
      },
      "prev" => op["prev"],
      "sig" => op["sig"]
    }
  end

  defp normalize(op), do: op
end
