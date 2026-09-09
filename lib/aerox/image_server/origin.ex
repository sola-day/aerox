defmodule Aerox.ImageServer.Origin do
  @moduledoc """
  Origin fetch (DESIGN §16): DID → DID document through the identity cache →
  `#atproto_pds` endpoint → `GET <pds>/xrpc/com.atproto.sync.getBlob`. Only a
  URL derived from a resolved DID document is ever fetched, through the
  hardened `Aerox.Identity.HTTP` client (SSRF rules; `allow_private` comes
  from its config for the all-in-one dev stack).

  Config, under `config :aerox, Aerox.ImageServer.Origin`:
  `identity_cache` (default `Aerox.AppView.Identity`), `http` (extra
  `Aerox.Identity.HTTP` options, e.g. a test `plug:`), `timeout` (ms).
  """

  alias Aerox.ATProto.CID
  alias Aerox.Identity.HTTP

  @default_timeout 10_000
  @default_max_bytes 20 * 1024 * 1024

  @type error :: :not_found | :not_an_image | :upstream

  @doc """
  Fetches and CID-verifies a blob. `{:error, :not_found}` covers an
  unresolvable DID, a document without a PDS, any 4xx from the PDS (not found,
  takedown, suspension — upstream maps all 4xx to 404), and a CID mismatch
  (upstream's `VerifyCidError` → 404); a 200 whose content type is definitely
  not an image is `{:error, :not_an_image}` (upstream: 400 "Not an image");
  anything else the origin does wrong is `{:error, :upstream}`.
  """
  @spec fetch(String.t(), String.t(), keyword) ::
          {:ok, binary, String.t() | nil} | {:error, error}
  def fetch(did, cid, opts \\ []) do
    with {:ok, parsed} <- parse_cid(cid),
         {:ok, pds} <- pds_endpoint(did),
         {:ok, body, content_type} <- get_blob(pds, did, cid, opts) do
      if CID.verify(parsed, body), do: {:ok, body, content_type}, else: {:error, :not_found}
    end
  end

  @doc "The PDS endpoint for a DID, through the configured identity cache."
  @spec pds_endpoint(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def pds_endpoint(did) do
    case Aerox.Identity.resolve_did(config(:identity_cache, Aerox.AppView.Identity), did) do
      {:ok, doc} ->
        case Aerox.ATProto.Identity.pds_endpoint(doc) do
          nil -> {:error, :not_found}
          url -> {:ok, url}
        end

      {:error, _} ->
        {:error, :not_found}
    end
  end

  defp parse_cid(cid) do
    case CID.parse(cid) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc "GET `<pds>/xrpc/com.atproto.sync.getBlob`, status-mapped."
  @spec get_blob(String.t(), String.t(), String.t(), keyword) ::
          {:ok, binary, String.t() | nil} | {:error, error}
  def get_blob(pds, did, cid, opts \\ []) do
    url =
      String.trim_trailing(pds, "/") <>
        "/xrpc/com.atproto.sync.getBlob?" <> URI.encode_query(%{"did" => did, "cid" => cid})

    http_opts =
      [
        timeout: Keyword.get(opts, :timeout, config(:timeout, @default_timeout)),
        max_bytes: Keyword.get(opts, :max_bytes, @default_max_bytes)
      ]
      |> Keyword.merge(config(:http, []))
      |> Keyword.merge(Keyword.get(opts, :http, []))

    case HTTP.get(url, http_opts) do
      {:ok, 200, headers, body} ->
        content_type = header(headers, "content-type")
        # Definitely not an image? Fail right away (upstream server.ts).
        if image_mime?(content_type) == false,
          do: {:error, :not_an_image},
          else: {:ok, body, content_type}

      # upstream blob-resolver: any 4xx (not found, takedown, suspended) => 404
      {:ok, status, _headers, _body} when status in 400..499 ->
        {:error, :not_found}

      {:ok, _status, _headers, _body} ->
        {:error, :upstream}

      {:error, {:body_too_large, _}} ->
        {:error, :upstream}

      {:error, _} ->
        {:error, :upstream}
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == name, do: v end)
  end

  # nil = maybe (no or generic content type), true/false otherwise
  defp image_mime?(nil), do: nil

  defp image_mime?(value) do
    mime = value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()

    cond do
      mime == "" or mime == "application/octet-stream" -> nil
      String.starts_with?(mime, "image/") -> true
      true -> false
    end
  end

  defp config(key, default),
    do: Keyword.get(Application.get_env(:aerox, __MODULE__, []), key, default)
end
