defmodule Aerox.ATProto.Identity do
  @moduledoc """
  DID document *parsing* — the pure half of DESIGN §3.0 (resolution lives in
  `Aerox.Identity`). Transcribed from `common-web/src/did-doc.ts`. Nothing
  here hard-codes the set of verification methods or services (DESIGN §8
  item 7): `verification_material/2` and `service_endpoint/3` take the id.
  """
  alias Aerox.ATProto.Crypto

  @type doc :: %{String.t() => term}

  @doc "Minimal shape check: an `id` string, list-valued optional sections."
  @spec valid_doc?(term) :: boolean
  def valid_doc?(%{"id" => id} = doc) when is_binary(id) do
    Enum.all?(["alsoKnownAs", "verificationMethod", "service"], fn k ->
      case Map.get(doc, k) do
        nil -> true
        list when is_list(list) -> true
        _ -> false
      end
    end)
  end

  def valid_doc?(_), do: false

  @spec did(doc) :: String.t()
  def did(%{"id" => id}) when is_binary(id), do: id

  @doc "The handle: the first `at://` alias, without the scheme."
  @spec handle(doc) :: String.t() | nil
  def handle(doc) do
    doc
    |> Map.get("alsoKnownAs", [])
    |> Enum.find_value(fn
      "at://" <> handle -> handle
      _ -> nil
    end)
  end

  @doc "Every `at://` alias."
  @spec handles(doc) :: [String.t()]
  def handles(doc) do
    for "at://" <> handle <- Map.get(doc, "alsoKnownAs", []), do: handle
  end

  @doc "`{type, publicKeyMultibase}` of the verification method `#<key_id>`."
  @spec verification_material(doc, String.t()) ::
          {:ok, %{type: String.t(), multibase: String.t()}} | :error
  def verification_material(doc, key_id) do
    case find_by_id(doc, "verificationMethod", "#" <> key_id) do
      %{"publicKeyMultibase" => mb} = vm when is_binary(mb) ->
        {:ok, %{type: Map.get(vm, "type"), multibase: mb}}

      _ ->
        :error
    end
  end

  @doc "The `#atproto` signing key as a `did:key`."
  @spec signing_did_key(doc) :: {:ok, String.t()} | :error
  def signing_did_key(doc), do: did_key_for(doc, "atproto")

  @doc "The verification method `#<key_id>` as a `did:key`."
  @spec did_key_for(doc, String.t()) :: {:ok, String.t()} | :error
  def did_key_for(doc, key_id) do
    with {:ok, %{multibase: mb, type: type}} <- verification_material(doc, key_id),
         {:ok, did_key} <- Crypto.did_key_from_verification_method(type, mb) do
      {:ok, did_key}
    else
      _ -> :error
    end
  end

  @doc "The `#atproto_pds` endpoint (type `AtprotoPersonalDataServer`)."
  @spec pds_endpoint(doc) :: String.t() | nil
  def pds_endpoint(doc), do: service_endpoint(doc, "#atproto_pds", "AtprotoPersonalDataServer")

  @spec feed_generator_endpoint(doc) :: String.t() | nil
  def feed_generator_endpoint(doc), do: service_endpoint(doc, "#bsky_fg", "BskyFeedGenerator")

  @spec labeler_endpoint(doc) :: String.t() | nil
  def labeler_endpoint(doc), do: service_endpoint(doc, "#atproto_labeler", "AtprotoLabeler")

  @doc "An http(s) service endpoint by id (and type, when given)."
  @spec service_endpoint(doc, String.t(), String.t() | nil) :: String.t() | nil
  def service_endpoint(doc, id, type \\ nil) do
    case find_by_id(doc, "service", id) do
      %{"serviceEndpoint" => url} = svc when is_binary(url) ->
        if (type == nil or svc["type"] == type) and http_url?(url), do: url, else: nil

      _ ->
        nil
    end
  end

  @doc "All services as `%{id => %{type, endpoint}}` with ids normalised to `#fragment`."
  @spec services(doc) :: %{String.t() => %{type: String.t() | nil, endpoint: String.t()}}
  def services(doc) do
    did = doc["id"]

    for %{"id" => id, "serviceEndpoint" => url} = svc <- Map.get(doc, "service", []),
        is_binary(url),
        into: %{} do
      {normalise_id(id, did), %{type: svc["type"], endpoint: url}}
    end
  end

  defp find_by_id(%{"id" => did} = doc, section, id) do
    Enum.find(Map.get(doc, section, []), fn
      %{"id" => item_id} when is_binary(item_id) -> normalise_id(item_id, did) == id
      _ -> false
    end)
  end

  defp normalise_id("#" <> _ = id, _did), do: id

  defp normalise_id(id, did) do
    if String.starts_with?(id, did <> "#"),
      do: binary_part(id, byte_size(did), byte_size(id) - byte_size(did)),
      else: id
  end

  defp http_url?(url) do
    String.starts_with?(url, ["http://", "https://"]) and
      match?(%URI{host: h} when is_binary(h) and h != "", URI.parse(url))
  end
end
