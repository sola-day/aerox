defmodule Aerox.Identity.LexiconResolver do
  @moduledoc """
  Lexicon Publication and Resolution (Lexicon spec; upstream
  `@atproto/lexicon-resolver`), uncached:

  1. the NSID's authority — every segment but the name, reversed — names a DNS
     TXT record `_lexicon.<authority>` holding exactly one `did=<did>`; the
     lookup is not hierarchical, so a missing record is a failure;
  2. the DID resolves to a document with a PDS and a signing key;
  3. that PDS serves `com.atproto.sync.getRecord` for
     `at://<did>/com.atproto.lexicon.schema/<nsid>`, and the proof is verified
     against the signing key (`Aerox.ATProto.Repo.verify_record_proof/5`);
  4. the record is a `com.atproto.lexicon.schema` with `lexicon: 1` and the
     same `id`, and is a well-formed lexicon document.

  DNS goes through `Aerox.Identity.DNS`, HTTP through `Aerox.Identity.HTTP`.
  """
  alias Aerox.ATProto.{CID, Identity, Repo, Syntax}
  alias Aerox.ATProto.Lexicon.Schema
  alias Aerox.Identity.{DNS, HTTP, Resolver}

  @collection "com.atproto.lexicon.schema"

  @type resolution :: %{uri: String.t(), cid: String.t(), did: String.t(), record: map}

  @doc "`_lexicon.<authority>` for an NSID."
  @spec dns_name(String.t()) :: String.t()
  def dns_name(nsid) do
    authority = nsid |> String.split(".") |> Enum.drop(-1) |> Enum.reverse() |> Enum.join(".")
    "_lexicon." <> authority
  end

  @spec resolve(String.t(), keyword) :: {:ok, resolution} | {:error, term}
  def resolve(nsid, opts \\ []) do
    with :ok <- if(Syntax.valid_nsid?(nsid), do: :ok, else: {:error, :invalid_nsid}),
         {:ok, did} <- did_authority(nsid, opts),
         {:ok, doc} <- Resolver.resolve_did(did, opts),
         pds when is_binary(pds) <- Identity.pds_endpoint(doc) || {:error, :no_pds},
         {:ok, key} <- Identity.signing_did_key(doc) |> ok_or(:no_signing_key),
         {:ok, car} <- fetch_proof(pds, did, nsid, opts),
         {:ok, %{cid: cid, record: record}} <-
           Repo.verify_record_proof(car, did, @collection, nsid, key),
         {:ok, record} <- check_record(record, nsid) do
      {:ok,
       %{
         uri: "at://#{did}/#{@collection}/#{nsid}",
         cid: CID.to_string(cid),
         did: did,
         record: record
       }}
    end
  end

  defp did_authority(nsid, opts) do
    case DNS.txt(dns_name(nsid), dns: opts[:dns], timeout: Keyword.get(opts, :timeout, 3_000)) do
      {:ok, records} ->
        case for("did=" <> did <- records, do: did) do
          [did] ->
            if Syntax.valid_did?(did), do: {:ok, did}, else: {:error, :invalid_did_authority}

          _ ->
            {:error, :no_did_authority}
        end

      {:error, _} ->
        {:error, :no_did_authority}
    end
  end

  defp fetch_proof(pds, did, nsid, opts) do
    url =
      pds <>
        "/xrpc/com.atproto.sync.getRecord?" <>
        URI.encode_query(did: did, collection: @collection, rkey: nsid)

    http = Keyword.merge([timeout: 5_000, max_bytes: 1_100_000], Keyword.get(opts, :http, []))

    case HTTP.get(url, http) do
      {:ok, 200, _, car} -> {:ok, car}
      {:ok, status, _, _} -> {:error, {:http_status, status}}
      {:error, _} = e -> e
    end
  end

  # the record as stored is the lexicon document plus `$type`
  defp check_record(%{"$type" => @collection, "lexicon" => 1, "id" => id} = record, nsid) do
    cond do
      id != nsid ->
        {:error, {:id_mismatch, id}}

      true ->
        doc = record |> Map.delete("$type") |> Aerox.ATProto.Data.to_json()

        case Schema.check_doc(doc) do
          {:ok, _} -> {:ok, record}
          {:error, reason} -> {:error, {:invalid_lexicon, reason}}
        end
    end
  end

  defp check_record(_, _), do: {:error, :not_a_lexicon_schema_record}

  defp ok_or({:ok, v}, _), do: {:ok, v}
  defp ok_or(_, reason), do: {:error, reason}
end
