defmodule Aerox.Crypto.Signer.Remote do
  @moduledoc """
  DESIGN §14.2: a separate tiny signing service holds the rotation key on
  another host. Protocol (JSON over HTTPS, a shared bearer secret):

      GET  <url>/key            → {"did_key": "did:key:z…"}
      POST <url>/sign  {"message": <base64url>} → {"signature": <base64url raw 64-byte low-S>}

  The private key never enters this process. Config:
  `adapter: Aerox.Crypto.Signer.Remote, url: "https://…", secret: "…"`
  (secret from `/etc/aerox/<env>.env`, never the repo). The `did:key` is
  fetched once at init and pinned; a signature that does not verify under it
  is refused (a misconfigured or compromised signer cannot inject signatures).
  """
  @behaviour Aerox.Crypto.Signer
  alias Aerox.ATProto.Crypto

  def init(config) do
    url = Keyword.fetch!(config, :url) |> String.trim_trailing("/")
    secret = Keyword.fetch!(config, :secret)
    did_key = Keyword.get(config, :did_key) || fetch_did_key!(url, secret, config)
    %{url: url, secret: secret, did_key: did_key, req: Keyword.get(config, :req_options, [])}
  end

  defp fetch_did_key!(url, secret, config) do
    resp =
      Req.get!(
        url <> "/key",
        [headers: [{"authorization", "Bearer " <> secret}], retry: false] ++
          Keyword.get(config, :req_options, [])
      )

    case resp do
      %{status: 200, body: %{"did_key" => "did:key:" <> _ = did_key}} ->
        did_key

      other ->
        raise ArgumentError,
              "remote signer at #{url} did not return its did:key (#{inspect(other.status)})"
    end
  end

  @impl true
  def did_key(%{did_key: did_key}), do: did_key

  @impl true
  def sign(%{url: url, secret: secret, did_key: did_key, req: req_opts}, message) do
    bytes = IO.iodata_to_binary(message)

    case Req.post(
           [
             url: url <> "/sign",
             json: %{"message" => Base.url_encode64(bytes, padding: false)},
             headers: [{"authorization", "Bearer " <> secret}],
             retry: false
           ] ++ req_opts
         ) do
      {:ok, %{status: 200, body: %{"signature" => b64}}} ->
        with {:ok, sig} <- Base.url_decode64(b64, padding: false),
             true <- Crypto.verify_did_sig(did_key, bytes, sig) do
          {:ok, sig}
        else
          _ -> {:error, :signature_does_not_verify}
        end

      {:ok, %{status: status}} ->
        {:error, {:remote_signer, status}}

      {:error, reason} ->
        {:error, {:remote_signer, reason}}
    end
  end
end
