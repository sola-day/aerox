defmodule Aerox.Labeler.PDSClient do
  @moduledoc """
  The Labeler's calls to a subject's PDS (DESIGN §17.2, upstream ozone's
  `getPdsAgentForRepo` + `createServiceJwt`): the PDS is the
  `#atproto_pds` endpoint of the subject's DID document (resolved through
  the Labeler's identity cache), the request carries a service JWT signed
  by the labeler key with `iss` = the labeler DID, `aud` = `did:web:<pds
  host>` and `lxm` = the method, over `Aerox.Identity.HTTP`.
  """
  require Logger
  alias Aerox.Auth.ServiceJWT
  alias Aerox.Identity.HTTP
  alias Aerox.Labeler.{Config, Subject}

  @update_status "com.atproto.admin.updateSubjectStatus"

  @doc "Sets (`ref`) or clears (`nil`) the takedown of a subject on its PDS."
  @spec update_takedown(map, String.t() | nil) :: :ok | {:error, term}
  def update_takedown(subject, ref) do
    takedown =
      if ref, do: %{"applied" => true, "ref" => ref}, else: %{"applied" => false}

    case call(Subject.did(subject), @update_status, %{
           "subject" => subject,
           "takedown" => takedown
         }) do
      {:ok, _body} -> :ok
      {:error, _} = e -> e
    end
  end

  @doc "POSTs an XRPC procedure to the PDS hosting `did`."
  @spec call(String.t(), String.t(), map) :: {:ok, map} | {:error, term}
  def call(did, nsid, input) do
    with {:ok, pds_url} <- pds_url(did) do
      aud = "did:web:" <> URI.parse(pds_url).host

      jwt =
        ServiceJWT.create(
          keypair: Config.signing_keypair(),
          iss: Config.did(),
          aud: aud,
          lxm: nsid
        )

      url = String.trim_trailing(pds_url, "/") <> "/xrpc/" <> nsid

      opts =
        Keyword.merge(
          [
            headers: [
              {"authorization", "Bearer " <> jwt},
              {"content-type", "application/json"}
            ],
            timeout: 15_000,
            allow_private: true
          ],
          Application.get_env(:aerox, __MODULE__, [])[:http] || []
        )

      case HTTP.post(url, Jason.encode!(input), opts) do
        {:ok, status, _headers, body} when status in 200..299 ->
          {:ok, if(body == "", do: %{}, else: Jason.decode!(body))}

        {:ok, status, _headers, body} ->
          Logger.warning("labeler: #{nsid} on #{pds_url} failed status=#{status} body=#{body}")
          {:error, {:pds_status, status, body}}

        {:error, reason} ->
          Logger.warning("labeler: #{nsid} on #{pds_url} unreachable: #{inspect(reason)}")
          {:error, {:pds_unreachable, reason}}
      end
    end
  end

  defp pds_url(did) do
    case Aerox.Identity.resolve_did(Aerox.Labeler.Identity, did) do
      {:ok, doc} ->
        case Aerox.ATProto.Identity.pds_endpoint(doc) do
          nil -> {:error, :no_pds_endpoint}
          url -> {:ok, url}
        end

      {:error, reason} ->
        {:error, {:unresolvable_did, reason}}
    end
  end
end
