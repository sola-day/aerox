defmodule Aerox.Identity.Resolver do
  @moduledoc """
  Uncached resolution (DESIGN §20.1), transcribed from `@atproto/identity`:

  * handle → DID: DNS TXT `_atproto.<handle>` (`did=…`, exactly one) first,
    then HTTPS `https://<handle>/.well-known/atproto-did` (first line).
  * `did:plc` → the configured directory's `GET /<did>`; `did:web` → HTTPS
    `/.well-known/did.json` (plain http only for `localhost`, as upstream);
    the document's `id` must equal the DID.

  Every network call goes through `Aerox.Identity.HTTP` and the DNS behaviour.
  """
  alias Aerox.ATProto.{Identity, Syntax}
  alias Aerox.Identity.{DNS, HTTP}

  @type opts :: [plc_url: String.t(), timeout: pos_integer, http: keyword, dns: module]

  @doc "The DID a handle points at, or an error."
  @spec resolve_handle(String.t(), opts) :: {:ok, String.t()} | {:error, :not_found | term}
  def resolve_handle(handle, opts \\ []) do
    with :ok <- if(Syntax.valid_handle?(handle), do: :ok, else: {:error, :invalid_handle}) do
      case resolve_handle_dns(handle, opts) do
        {:ok, did} -> {:ok, did}
        _ -> resolve_handle_http(handle, opts)
      end
    end
  end

  @spec resolve_handle_dns(String.t(), opts) :: {:ok, String.t()} | {:error, term}
  def resolve_handle_dns(handle, opts \\ []) do
    case DNS.txt("_atproto." <> handle,
           dns: opts[:dns],
           timeout: Keyword.get(opts, :timeout, 3_000)
         ) do
      {:ok, records} ->
        case Enum.filter(records, &String.starts_with?(&1, "did=")) do
          [one] -> {:ok, String.replace_prefix(one, "did=", "")}
          _ -> {:error, :not_found}
        end

      {:error, _} = e ->
        e
    end
  end

  @spec resolve_handle_http(String.t(), opts) :: {:ok, String.t()} | {:error, term}
  def resolve_handle_http(handle, opts \\ []) do
    http_opts =
      Keyword.merge(
        [timeout: Keyword.get(opts, :timeout, 3_000), max_bytes: 4_096],
        Keyword.get(opts, :http, [])
      )

    case HTTP.get("https://#{handle}/.well-known/atproto-did", http_opts) do
      {:ok, 200, _, body} ->
        did = body |> String.split("\n", parts: 2) |> hd() |> String.trim()
        if Syntax.valid_did?(did), do: {:ok, did}, else: {:error, :not_found}

      {:ok, _status, _, _} ->
        {:error, :not_found}

      {:error, _} = e ->
        e
    end
  end

  @doc "The DID document for a `did:plc` or `did:web`."
  @spec resolve_did(String.t(), opts) :: {:ok, Identity.doc()} | {:error, :not_found | term}
  def resolve_did(did, opts \\ []) do
    with :ok <- if(Syntax.valid_did?(did), do: :ok, else: {:error, :invalid_did}) do
      result =
        case Syntax.did_method(did) do
          "plc" -> resolve_plc(did, opts)
          "web" -> resolve_web(did, opts)
          other -> {:error, {:unsupported_did_method, other}}
        end

      with {:ok, doc} <- result do
        if Identity.valid_doc?(doc) and doc["id"] == did,
          do: {:ok, doc},
          else: {:error, :poorly_formatted_did_document}
      end
    end
  end

  defp resolve_plc(did, opts) do
    plc_url =
      Keyword.get(opts, :plc_url) || Application.get_env(:aerox, :plc_url) ||
        "https://plc.directory"

    fetch_json("#{String.trim_trailing(plc_url, "/")}/#{URI.encode(did)}", opts)
  end

  defp resolve_web(did, opts) do
    parts =
      did |> String.replace_prefix("did:web:", "") |> String.split(":") |> Enum.map(&URI.decode/1)

    case parts do
      [host] ->
        scheme =
          if host == "localhost" or String.starts_with?(host, "localhost:"),
            do: "http",
            else: "https"

        fetch_json("#{scheme}://#{host}/.well-known/did.json", opts)

      _ ->
        {:error, :unsupported_did_web_path}
    end
  end

  defp fetch_json(url, opts) do
    http_opts =
      Keyword.merge(
        [
          timeout: Keyword.get(opts, :timeout, 3_000),
          max_bytes: 100_000,
          headers: [{"accept", "application/did+ld+json,application/json"}]
        ],
        Keyword.get(opts, :http, [])
      )

    case HTTP.get(url, http_opts) do
      {:ok, 200, _, body} ->
        case Jason.decode(body) do
          {:ok, %{} = doc} -> {:ok, doc}
          _ -> {:error, :poorly_formatted_did_document}
        end

      {:ok, 404, _, _} ->
        {:error, :not_found}

      {:ok, status, _, _} ->
        {:error, {:http_status, status}}

      {:error, _} = e ->
        e
    end
  end

  @doc """
  Bidirectional resolution of a handle: DID from the handle, document from
  the DID, and the document's `alsoKnownAs` must contain the handle — or the
  handle is `handle.invalid` (DESIGN §20.1).
  """
  @spec verify_handle(String.t(), opts) :: {:ok, String.t(), Identity.doc()} | {:error, term}
  def verify_handle(handle, opts \\ []) do
    handle = Syntax.normalize_handle(handle)

    with {:ok, did} <- resolve_handle(handle, opts),
         {:ok, doc} <- resolve_did(did, opts) do
      if handle in Enum.map(Identity.handles(doc), &Syntax.normalize_handle/1),
        do: {:ok, did, doc},
        else: {:error, :handle_mismatch}
    end
  end
end
