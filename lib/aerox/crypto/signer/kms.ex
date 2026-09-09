defmodule Aerox.Crypto.Signer.Kms do
  @moduledoc """
  DESIGN §14.2: AWS KMS asymmetric secp256k1 (`ECC_SECG_P256K1`,
  `ECDSA_SHA_256`), matching upstream's `@atproto/aws` `KmsKeypair` so a
  migrated deployment keeps its existing key. Uses the KMS JSON API directly
  with SigV4 (no AWS SDK dependency): `GetPublicKey` once at init (DER SPKI →
  compressed point → `did:key`), `Sign` with `MessageType: DIGEST` per
  operation; KMS returns DER `r‖s`, which is converted to the raw low-S form
  the protocol requires (§3.8).

  Config: `adapter: Aerox.Crypto.Signer.Kms, key_id:, region:, access_key_id:,
  secret_access_key:` (+ optional `session_token:`, `endpoint:` for tests).
  """
  @behaviour Aerox.Crypto.Signer
  alias Aerox.ATProto.Crypto

  @k256_n 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

  def init(config) do
    state = %{
      key_id: Keyword.fetch!(config, :key_id),
      region: Keyword.fetch!(config, :region),
      access_key_id: Keyword.fetch!(config, :access_key_id),
      secret_access_key: Keyword.fetch!(config, :secret_access_key),
      session_token: Keyword.get(config, :session_token),
      endpoint:
        Keyword.get(config, :endpoint) ||
          "https://kms.#{Keyword.fetch!(config, :region)}.amazonaws.com",
      req: Keyword.get(config, :req_options, [])
    }

    public = Keyword.get(config, :public_key) || fetch_public_key!(state)
    Map.put(state, :did_key, Crypto.format_did_key(:k256, public))
  end

  defp fetch_public_key!(state) do
    case request(state, "TrentService.GetPublicKey", %{"KeyId" => state.key_id}) do
      {:ok, %{"PublicKey" => der_b64, "KeySpec" => spec}} ->
        if spec != "ECC_SECG_P256K1",
          do: raise(ArgumentError, "KMS key #{state.key_id} is #{spec}, not ECC_SECG_P256K1")

        der_b64 |> Base.decode64!() |> spki_point() |> Crypto.compress()

      other ->
        raise ArgumentError, "KMS GetPublicKey failed: #{inspect(other)}"
    end
  end

  # SubjectPublicKeyInfo: the uncompressed point is the last 65 bytes of the BIT STRING
  defp spki_point(der) do
    size = byte_size(der)
    binary_part(der, size - 65, 65)
  end

  @impl true
  def did_key(%{did_key: did_key}), do: did_key

  @impl true
  def sign(state, message) do
    digest = :crypto.hash(:sha256, message)

    case request(state, "TrentService.Sign", %{
           "KeyId" => state.key_id,
           "Message" => Base.encode64(digest),
           "MessageType" => "DIGEST",
           "SigningAlgorithm" => "ECDSA_SHA_256"
         }) do
      {:ok, %{"Signature" => sig_b64}} ->
        {r, s} = sig_b64 |> Base.decode64!() |> der_to_rs()
        s = if s > div(@k256_n, 2), do: @k256_n - s, else: s
        {:ok, <<r::256, s::256>>}

      {:error, reason} ->
        {:error, {:kms, reason}}
    end
  end

  defp der_to_rs(<<0x30, _len, 0x02, rlen, rest::binary>>) do
    <<r::binary-size(^rlen), 0x02, slen, s::binary-size(slen)>> = rest
    {:binary.decode_unsigned(r), :binary.decode_unsigned(s)}
  end

  # ------------------------------------------------------------ SigV4

  defp request(state, target, body) do
    payload = Jason.encode!(body)
    now = DateTime.utc_now()
    amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    date = Calendar.strftime(now, "%Y%m%d")
    uri = URI.parse(state.endpoint)
    host = uri.host

    headers =
      [
        {"content-type", "application/x-amz-json-1.1"},
        {"host", host},
        {"x-amz-date", amz_date},
        {"x-amz-target", target}
      ] ++ if(state.session_token, do: [{"x-amz-security-token", state.session_token}], else: [])

    signed_headers = headers |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> Enum.join(";")

    canonical_headers =
      headers |> Enum.sort() |> Enum.map_join("", fn {k, v} -> "#{k}:#{String.trim(v)}\n" end)

    payload_hash = sha256_hex(payload)

    canonical =
      Enum.join(["POST", "/", "", canonical_headers, signed_headers, payload_hash], "\n")

    scope = "#{date}/#{state.region}/kms/aws4_request"
    string_to_sign = Enum.join(["AWS4-HMAC-SHA256", amz_date, scope, sha256_hex(canonical)], "\n")

    k_date = hmac("AWS4" <> state.secret_access_key, date)
    k_region = hmac(k_date, state.region)
    k_service = hmac(k_region, "kms")
    k_signing = hmac(k_service, "aws4_request")
    signature = k_signing |> hmac(string_to_sign) |> Base.encode16(case: :lower)

    authorization =
      "AWS4-HMAC-SHA256 Credential=#{state.access_key_id}/#{scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}"

    req_headers =
      Enum.reject(headers, fn {k, _} -> k == "host" end) ++ [{"authorization", authorization}]

    case Req.post(
           [url: state.endpoint <> "/", body: payload, headers: req_headers, retry: false] ++
             state.req
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: 200, body: body}} when is_binary(body) -> Jason.decode(body)
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sha256_hex(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
end
