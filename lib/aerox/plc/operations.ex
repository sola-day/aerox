defmodule Aerox.PLC.Operations do
  @moduledoc """
  did:plc operation rules, pure (DESIGN §14.2 point 7). Transcribed from
  `did-method-plc/packages/lib/src/{operations,data,document}.ts` and the
  server's `constraints.ts` (commit 1e301e5e); pinned by the audit-log
  vectors in `test/golden/plc/`.

  Operations are string-keyed maps as they travel in JSON. Signing encodes
  the unsigned map as DAG-CBOR; `sig` is unpadded base64url. The DID is
  `did:plc:` + the first 24 base32 characters of sha256 of the signed
  genesis operation's DAG-CBOR. Nullification: a later operation whose
  `prev` points back into history nullifies everything after `prev`, but
  only if signed by a rotation key of *higher* priority (lower index) than
  the one that signed the first nullified op, and within 72 hours of it.
  """
  alias Aerox.ATProto.{CID, Crypto, DagCBOR, Syntax}

  @recovery_window_ms 72 * 60 * 60 * 1000

  @type op :: %{String.t() => term}
  @type indexed :: %{
          did: String.t(),
          operation: op,
          cid: CID.t(),
          nullified: boolean,
          created_at: DateTime.t()
        }
  @type document_data :: %{
          did: String.t(),
          rotation_keys: [String.t()],
          verification_methods: %{String.t() => String.t()},
          also_known_as: [String.t()],
          services: %{String.t() => %{type: String.t(), endpoint: String.t()}}
        }

  defmodule Error do
    @moduledoc "A PLC validation failure; `kind` mirrors upstream's error classes."
    defexception [:kind, :message]
    @type t :: %__MODULE__{kind: atom, message: String.t()}
  end

  # ------------------------------------------------------------ shapes

  @doc "True for `plc_operation`, `plc_tombstone` and the legacy `create` shape (strict: no extra keys)."
  @spec valid_shape?(term) :: boolean
  def valid_shape?(op), do: shape(op) != :invalid

  @doc false
  def shape(%{"type" => "plc_operation"} = op) do
    keys = Map.keys(op) |> Enum.sort()

    if keys == Enum.sort(~w(alsoKnownAs prev rotationKeys services sig type verificationMethods)) and
         is_list(op["rotationKeys"]) and Enum.all?(op["rotationKeys"], &is_binary/1) and
         is_map(op["verificationMethods"]) and
         Enum.all?(op["verificationMethods"], fn {k, v} -> is_binary(k) and is_binary(v) end) and
         is_list(op["alsoKnownAs"]) and Enum.all?(op["alsoKnownAs"], &is_binary/1) and
         is_map(op["services"]) and Enum.all?(op["services"], &valid_service?/1) and
         (is_nil(op["prev"]) or is_binary(op["prev"])) and is_binary(op["sig"]),
       do: :operation,
       else: :invalid
  end

  def shape(%{"type" => "plc_tombstone"} = op) do
    if Map.keys(op) |> Enum.sort() == Enum.sort(~w(prev sig type)) and is_binary(op["prev"]) and
         is_binary(op["sig"]),
       do: :tombstone,
       else: :invalid
  end

  def shape(%{"type" => "create"} = op) do
    keys = Map.keys(op) |> Enum.sort()

    if keys == Enum.sort(~w(handle prev recoveryKey service signingKey sig type)) and
         Enum.all?(~w(handle recoveryKey service signingKey sig), &is_binary(op[&1])) and
         is_nil(op["prev"]),
       do: :legacy_create,
       else: :invalid
  end

  def shape(_), do: :invalid

  defp valid_service?({id, %{"type" => t, "endpoint" => e} = svc}),
    do: is_binary(id) and is_binary(t) and is_binary(e) and map_size(svc) == 2

  defp valid_service?(_), do: false

  @doc "Whether the op is a tombstone."
  @spec tombstone?(op) :: boolean
  def tombstone?(%{"type" => "plc_tombstone"}), do: true
  def tombstone?(_), do: false

  @doc "The legacy `create` op in `plc_operation` form (upstream `normalizeOp`)."
  @spec normalize(op) :: op
  def normalize(%{"type" => "create"} = op) do
    %{
      "type" => "plc_operation",
      "verificationMethods" => %{"atproto" => op["signingKey"]},
      "rotationKeys" => [op["recoveryKey"], op["signingKey"]],
      "alsoKnownAs" => [ensure_at_prefix(op["handle"])],
      "services" => %{
        "atproto_pds" => %{
          "type" => "AtprotoPersonalDataServer",
          "endpoint" => ensure_http_prefix(op["service"])
        }
      },
      "prev" => op["prev"],
      "sig" => op["sig"]
    }
  end

  def normalize(op), do: op

  # ---------------------------------------------------------- encoding

  @doc "DAG-CBOR bytes of an op exactly as the reference encodes it (the `sig` string included when present)."
  @spec encode(op) :: binary
  def encode(op), do: DagCBOR.encode(op)

  @spec cid(op) :: CID.t()
  def cid(op), do: CID.for_cbor(encode(op))

  @doc "`did:plc:` + first 24 base32 chars of sha256(dag-cbor(op))."
  @spec did_for_create_op(op) :: String.t()
  def did_for_create_op(op) do
    hash = :crypto.hash(:sha256, encode(op))
    "did:plc:" <> (hash |> Base.encode32(case: :lower, padding: false) |> binary_part(0, 24))
  end

  @doc "Signs an unsigned op with a keypair, adding unpadded base64url `sig`."
  @spec sign(op, Crypto.Keypair.t()) :: op
  def sign(unsigned, %Crypto.Keypair{} = kp) do
    unsigned = Map.delete(unsigned, "sig")
    Map.put(unsigned, "sig", Base.url_encode64(Crypto.sign(kp, encode(unsigned)), padding: false))
  end

  @doc "The unsigned `plc_operation` for an atproto account (upstream `formatAtprotoOp`)."
  @spec format_atproto_op(keyword) :: op
  def format_atproto_op(opts) do
    %{
      "type" => "plc_operation",
      "verificationMethods" => %{"atproto" => Keyword.fetch!(opts, :signing_key)},
      "rotationKeys" => Keyword.fetch!(opts, :rotation_keys),
      "alsoKnownAs" => [ensure_at_prefix(Keyword.fetch!(opts, :handle))],
      "services" => %{
        "atproto_pds" => %{
          "type" => "AtprotoPersonalDataServer",
          "endpoint" => ensure_http_prefix(Keyword.fetch!(opts, :pds))
        }
      },
      "prev" => opts |> Keyword.get(:prev) |> then(&if(&1, do: to_string(&1)))
    }
  end

  @doc "A signed genesis op and its DID."
  @spec create_op(keyword, Crypto.Keypair.t()) :: {op, String.t()}
  def create_op(opts, signer) do
    op = opts |> Keyword.put(:prev, nil) |> format_atproto_op() |> sign(signer)
    {op, did_for_create_op(op)}
  end

  @doc "An update op: the normalised last op, edited by `fun`, with `prev` = cid(last), signed."
  @spec create_update_op(op, Crypto.Keypair.t(), (op -> op)) :: op
  def create_update_op(last_op, signer, fun) do
    prev = cid(last_op)
    normalized = last_op |> normalize() |> Map.delete("sig")
    normalized |> fun.() |> Map.put("prev", CID.to_string(prev)) |> sign(signer)
  end

  @doc "Upstream `createAtprotoUpdateOp`: change any of signing_key / handle / pds / rotation_keys."
  @spec atproto_update_op(op, Crypto.Keypair.t(), keyword) :: op
  def atproto_update_op(last_op, signer, changes) do
    create_update_op(last_op, signer, fn n ->
      n
      |> then(
        &if(k = changes[:signing_key],
          do: put_in(&1, ["verificationMethods", "atproto"], k),
          else: &1
        )
      )
      |> then(
        &if(h = changes[:handle],
          do: Map.put(&1, "alsoKnownAs", replace_handle(&1["alsoKnownAs"], ensure_at_prefix(h))),
          else: &1
        )
      )
      |> then(
        &if(p = changes[:pds],
          do:
            put_in(&1, ["services", "atproto_pds"], %{
              "type" => "AtprotoPersonalDataServer",
              "endpoint" => ensure_http_prefix(p)
            }),
          else: &1
        )
      )
      |> then(&if(r = changes[:rotation_keys], do: Map.put(&1, "rotationKeys", r), else: &1))
    end)
  end

  defp replace_handle(akas, formatted) do
    case Enum.find_index(akas, &String.starts_with?(&1, "at://")) do
      nil -> [formatted | akas]
      i -> List.replace_at(akas, i, formatted)
    end
  end

  @spec tombstone_op(CID.t(), Crypto.Keypair.t()) :: op
  def tombstone_op(prev, signer),
    do: sign(%{"type" => "plc_tombstone", "prev" => CID.to_string(prev)}, signer)

  # -------------------------------------------------------- validation

  @doc "Returns the rotation key that signed `op`, or an error. Base64url must be unpadded and canonical."
  @spec assure_valid_sig([String.t()], op) :: {:ok, String.t()} | {:error, Error.t()}
  def assure_valid_sig(allowed_did_keys, %{"sig" => sig} = op) when is_binary(sig) do
    with false <- String.ends_with?(sig, "="),
         {:ok, sig_bytes} <- decode_sig(sig) do
      data = op |> Map.delete("sig") |> encode()

      case Enum.find(allowed_did_keys, &Crypto.verify_did_sig(&1, data, sig_bytes)) do
        nil -> {:error, error(:invalid_signature, "Invalid signature on op")}
        key -> {:ok, key}
      end
    else
      _ -> {:error, error(:invalid_signature, "Invalid signature on op")}
    end
  end

  def assure_valid_sig(_, _), do: {:error, error(:invalid_signature, "Invalid signature on op")}

  # Canonical unpadded base64url: no padding chars, no stray bits, alphabet only.
  defp decode_sig(sig) do
    with {:ok, bytes} <- Base.url_decode64(sig, padding: false),
         true <- Base.url_encode64(bytes, padding: false) == sig do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  @doc "A genesis op must be signed by one of its own rotation keys, hash to `did`, and have `prev: null`."
  @spec assure_valid_creation_op(String.t(), op) :: {:ok, document_data} | {:error, Error.t()}
  def assure_valid_creation_op(did, op) do
    cond do
      tombstone?(op) ->
        {:error, error(:misordered, "Operations not correctly ordered")}

      shape(op) == :invalid ->
        {:error, error(:improper, "Improperly formatted operation")}

      true ->
        normalized = normalize(op)

        with {:ok, _} <- assure_valid_sig(normalized["rotationKeys"], op),
             expected = did_for_create_op(op),
             true <-
               expected == did ||
                 {:error,
                  error(
                    :genesis_hash,
                    "Hash of genesis operation does not match DID identifier: #{expected}"
                  )},
             true <-
               is_nil(op["prev"]) ||
                 {:error,
                  error(:improper, "Improperly formatted operation, expected null prev on create")} do
          {:ok, to_data(did, normalized)}
        end
    end
  end

  @doc """
  Upstream `assureValidNextOp`: given the DID's indexed ops (oldest first,
  non-nullified), decide whether `proposed` at `proposed_at` is acceptable
  and which existing ops it nullifies.
  """
  @spec assure_valid_next_op(String.t(), [indexed], op, DateTime.t()) ::
          {:ok, %{nullified: [CID.t()], prev: CID.t() | nil}} | {:error, Error.t()}
  def assure_valid_next_op(did, [], proposed, _at) do
    with {:ok, _} <- assure_valid_creation_op(did, proposed),
         do: {:ok, %{nullified: [], prev: nil}}
  end

  def assure_valid_next_op(_did, ops, proposed, proposed_at) do
    with :ok <-
           if(shape(proposed) == :invalid,
             do: {:error, error(:improper, "Improperly formatted operation")},
             else: :ok
           ),
         {:ok, prev} <- parse_prev(proposed["prev"]),
         {:ok, index} <- find_prev(ops, prev),
         {history, nullified} = Enum.split(ops, index + 1),
         last = List.last(history),
         :ok <- if(tombstone?(last.operation), do: misordered(), else: :ok),
         last_norm = normalize(last.operation) do
      case nullified do
        [] ->
          with {:ok, _} <- assure_valid_sig(last_norm["rotationKeys"], proposed),
               do: {:ok, %{nullified: [], prev: prev}}

        [first | _] ->
          with {:ok, disputed} <- assure_valid_sig(last_norm["rotationKeys"], first.operation),
               index_of_signer = Enum.find_index(last_norm["rotationKeys"], &(&1 == disputed)),
               more_powerful = Enum.take(last_norm["rotationKeys"], index_of_signer),
               {:ok, _} <- assure_valid_sig(more_powerful, proposed),
               :ok <-
                 if(DateTime.compare(proposed_at, List.last(ops).created_at) != :gt,
                   do: misordered(),
                   else: :ok
                 ),
               :ok <- within_window(proposed_at, first.created_at) do
            {:ok, %{nullified: Enum.map(nullified, & &1.cid), prev: prev}}
          end
      end
    end
  end

  defp parse_prev(nil), do: misordered()

  defp parse_prev(prev) when is_binary(prev) do
    case CID.parse(prev) do
      {:ok, cid} -> {:ok, cid}
      _ -> misordered()
    end
  end

  defp find_prev(ops, prev) do
    case Enum.find_index(ops, &(&1.cid == prev)) do
      nil -> misordered()
      i -> {:ok, i}
    end
  end

  defp within_window(proposed_at, first_nullified_at) do
    lapsed = DateTime.diff(proposed_at, first_nullified_at, :millisecond)

    if lapsed > @recovery_window_ms,
      do:
        {:error,
         error(
           :late_recovery,
           "Recovery operation occurred outside of the allowed 72 hr recovery window. Time lapsed: #{lapsed}"
         )},
      else: :ok
  end

  defp misordered, do: {:error, error(:misordered, "Operations not correctly ordered")}

  @doc """
  Upstream `validateOperationLog`: replays a bare op log (no timestamps, so
  no nullification handling) and returns the final document data, or nil
  for a tombstoned DID.
  """
  @spec validate_operation_log(String.t(), [op]) ::
          {:ok, document_data | nil} | {:error, Error.t()}
  def validate_operation_log(_did, []),
    do: {:error, error(:improper, "Improperly formatted operation, incorrect structure")}

  def validate_operation_log(did, [first | rest]) do
    with :ok <-
           if(shape(first) in [:operation, :legacy_create],
             do: :ok,
             else:
               {:error, error(:improper, "Improperly formatted operation, incorrect structure")}
           ),
         :ok <-
           if(Enum.all?(rest, &(shape(&1) in [:operation, :tombstone])),
             do: :ok,
             else:
               {:error, error(:improper, "Improperly formatted operation, incorrect structure")}
           ),
         {:ok, doc} <- assure_valid_creation_op(did, first) do
      replay(did, rest, doc, cid(first))
    end
  end

  defp replay(_did, [], doc, _prev), do: {:ok, doc}

  defp replay(did, [op | rest], doc, prev) do
    with :ok <- if(op["prev"] == CID.to_string(prev), do: :ok, else: misordered()),
         {:ok, _} <- assure_valid_sig(doc.rotation_keys, op) do
      case op_to_data(did, op) do
        nil -> if rest == [], do: {:ok, nil}, else: misordered()
        data -> replay(did, rest, data, cid(op))
      end
    end
  end

  @doc """
  Replays a full audit log — indexed ops with timestamps and `nullified`
  flags, as `/log/audit` and the interop vectors carry them — through the
  directory's own admission rule, and checks the resulting nullification
  flags equal the log's. This is what makes a log "valid" for a directory.
  """
  @spec validate_audit_log([map]) :: :ok | {:error, term}
  def validate_audit_log(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, indexed} ->
      op = entry["operation"]
      did = entry["did"]

      with {:ok, at, _} <- DateTime.from_iso8601(entry["createdAt"]),
           active = Enum.reject(indexed, & &1.nullified),
           {:ok, %{nullified: nullified}} <- assure_valid_next_op(did, active, op, at),
           {:ok, claimed} <- CID.parse(entry["cid"]),
           :ok <-
             if(claimed == cid(op), do: :ok, else: {:error, error(:improper, "cid mismatch")}) do
        indexed =
          Enum.map(indexed, &if(&1.cid in nullified, do: %{&1 | nullified: true}, else: &1))

        {:cont,
         {:ok,
          indexed ++ [%{did: did, operation: op, cid: claimed, nullified: false, created_at: at}]}}
      else
        {:error, %Error{} = e} -> {:halt, {:error, e}}
        _ -> {:halt, {:error, error(:improper, "malformed audit log entry")}}
      end
    end)
    |> case do
      {:ok, indexed} ->
        expected = Enum.map(entries, & &1["nullified"])
        actual = Enum.map(indexed, & &1.nullified)
        if expected == actual, do: :ok, else: {:error, {:nullified_mismatch, expected, actual}}

      e ->
        e
    end
  end

  # ------------------------------------------------------- documents

  @doc "Document data from the latest op, or nil for a tombstone (upstream `opToData`)."
  @spec op_to_data(String.t(), op) :: document_data | nil
  def op_to_data(_did, %{"type" => "plc_tombstone"}), do: nil
  def op_to_data(did, op), do: to_data(did, normalize(op))

  defp to_data(did, n) do
    %{
      did: did,
      rotation_keys: n["rotationKeys"],
      verification_methods: n["verificationMethods"],
      also_known_as: n["alsoKnownAs"],
      services:
        Map.new(n["services"], fn {id, s} -> {id, %{type: s["type"], endpoint: s["endpoint"]}} end)
    }
  end

  @doc "The W3C DID document for document data (upstream `formatDidDoc`)."
  @spec format_did_doc(document_data) :: map
  def format_did_doc(data) do
    base_context = ["https://www.w3.org/ns/did/v1", "https://w3id.org/security/multikey/v1"]

    {methods, context} =
      Enum.map_reduce(data.verification_methods, base_context, fn {id, key}, ctx ->
        {type, extra} = key_type_and_context(key)

        {%{
           "id" => "#{data.did}##{id}",
           "type" => type,
           "controller" => data.did,
           "publicKeyMultibase" => String.replace_prefix(key, "did:key:", "")
         }, if(extra && extra not in ctx, do: ctx ++ [extra], else: ctx)}
      end)

    %{
      "@context" => context,
      "id" => data.did,
      "alsoKnownAs" => data.also_known_as,
      "verificationMethod" => methods,
      "service" =>
        Enum.map(data.services, fn {id, s} ->
          %{"id" => "##{id}", "type" => s.type, "serviceEndpoint" => s.endpoint}
        end)
    }
  end

  defp key_type_and_context(key) do
    case Crypto.parse_did_key(key) do
      {:ok, :p256, _} -> {"Multikey", "https://w3id.org/security/suites/ecdsa-2019/v1"}
      {:ok, :k256, _} -> {"Multikey", "https://w3id.org/security/suites/secp256k1-2019/v1"}
      _ -> {"Multikey", nil}
    end
  end

  # ------------------------------------------------------ constraints

  @max_op_bytes 4000
  @max_aka 10
  @max_aka_length 258
  @max_rotation 10
  @max_services 10
  @max_service_type 256
  @max_service_endpoint 512
  @max_verification_methods 10
  @max_id_length 32
  @max_did_key_length 256

  @doc "The server's incoming-op constraints (`constraints.ts`): size and entry limits, key encodings."
  @spec check_incoming_op(term) :: :ok | {:error, String.t()}
  def check_incoming_op(op) do
    cond do
      not is_map(op) ->
        {:error, "Not a valid operation"}

      byte_size(safe_encode(op)) > @max_op_bytes ->
        {:error, "Operation too large (#{@max_op_bytes} bytes maximum in cbor encoding)"}

      shape(op) not in [:operation, :tombstone] ->
        {:error, "Not a valid operation: #{Jason.encode!(op)}"}

      tombstone?(op) ->
        :ok

      true ->
        check_operation_limits(op)
    end
  end

  defp safe_encode(op) do
    DagCBOR.encode(op)
  rescue
    _ -> <<>>
  end

  defp check_operation_limits(op) do
    akas = op["alsoKnownAs"]
    rotation = op["rotationKeys"]
    services = op["services"]
    methods = op["verificationMethods"]

    cond do
      length(akas) > @max_aka ->
        {:error, "To many alsoKnownAs entries (max #{@max_aka})"}

      Enum.any?(akas, &(byte_size(&1) > @max_aka_length)) ->
        {:error, "alsoKnownAs entry too long (max #{@max_aka_length})"}

      length(Enum.uniq(akas)) != length(akas) ->
        {:error, "duplicate alsoKnownAs entry"}

      length(rotation) > @max_rotation ->
        {:error, "Too many rotationKey entries (max #{@max_rotation})"}

      Enum.any?(rotation, &(not match?({:ok, _, _}, Crypto.parse_did_key(&1)))) ->
        {:error, "Invalid rotationKey"}

      map_size(services) > @max_services ->
        {:error, "To many service entries (max #{@max_services})"}

      Enum.any?(services, fn {id, _} -> byte_size(id) > @max_id_length end) ->
        {:error, "Service id too long (max #{@max_id_length})"}

      Enum.any?(services, fn {_, s} -> byte_size(s["type"]) > @max_service_type end) ->
        {:error, "Service type too long (max #{@max_service_type})"}

      Enum.any?(services, fn {_, s} -> byte_size(s["endpoint"]) > @max_service_endpoint end) ->
        {:error, "Service endpoint too long (max #{@max_service_endpoint})"}

      map_size(methods) > @max_verification_methods ->
        {:error, "Too many Verification Method entries (max #{@max_verification_methods})"}

      Enum.any?(methods, fn {id, _} -> byte_size(id) > @max_id_length end) ->
        {:error, "Verification Method id too long (max #{@max_id_length})"}

      Enum.any?(methods, fn {_, k} -> byte_size(k) > @max_did_key_length end) ->
        {:error, "Verification Method key too long (max #{@max_did_key_length})"}

      Enum.any?(methods, fn {_, k} -> not did_key_shaped?(k) end) ->
        {:error, "Invalid verificationMethod key"}

      true ->
        :ok
    end
  end

  # did:key: prefix and base58btc body; the curve may be one we do not sign with.
  defp did_key_shaped?("did:key:z" <> b58), do: match?({:ok, _}, Aerox.ATProto.Base58.decode(b58))
  defp did_key_shaped?(_), do: false

  @doc "Validates the DID string itself for the routes."
  @spec valid_plc_did?(term) :: boolean
  def valid_plc_did?("did:plc:" <> rest = did),
    do: byte_size(rest) == 24 and Syntax.valid_did?(did)

  def valid_plc_did?(_), do: false

  # ------------------------------------------------------------ helpers

  defp ensure_http_prefix(str) do
    if String.starts_with?(str, ["http://", "https://"]), do: str, else: "https://" <> str
  end

  defp ensure_at_prefix("at://" <> _ = str), do: str

  defp ensure_at_prefix(str),
    do:
      "at://" <>
        (str |> String.replace_prefix("https://", "") |> String.replace_prefix("http://", ""))

  defp error(kind, message), do: %Error{kind: kind, message: message}
end
