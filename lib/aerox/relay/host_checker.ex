defmodule Aerox.Relay.HostChecker do
  @moduledoc "Reachability and account-status probes against a PDS (indigo `host_checker.go`)."
  alias Aerox.Identity.HTTP
  alias Aerox.Relay.Config

  @doc "`describeServer` must answer 200 with JSON (`CheckHost`)."
  def check_host(url) do
    case HTTP.get(url <> "/xrpc/com.atproto.server.describeServer", http_opts()) do
      {:ok, 200, _, body} ->
        case Jason.decode(body) do
          {:ok, %{"did" => _}} -> :ok
          _ -> {:error, "describeServer response is not valid"}
        end

      {:ok, status, _, _} ->
        {:error, "describeServer returned HTTP #{status}"}

      {:error, reason} ->
        {:error, "unreachable: #{inspect(reason)}"}
    end
  end

  @doc "`getRepoStatus` on the account's PDS → upstream status string (`FetchAccountStatus`)."
  def fetch_account_status(pds_url, did) do
    url = pds_url <> "/xrpc/com.atproto.sync.getRepoStatus?did=" <> URI.encode_www_form(did)

    case HTTP.get(url, http_opts()) do
      {:ok, 200, _, body} ->
        case Jason.decode(body) do
          {:ok, %{"active" => true}} -> {:ok, "active"}
          {:ok, %{"status" => s}} when is_binary(s) -> {:ok, s}
          {:ok, _} -> {:ok, "inactive"}
          _ -> {:error, :invalid_response}
        end

      {:ok, 404, _, _} ->
        {:ok, "deleted"}

      {:ok, status, _, _} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp http_opts do
    [timeout: 10_000, max_bytes: 1_000_000, allow_private: Config.allow_insecure_hosts?()] ++
      Keyword.take(Application.get_env(:aerox, __MODULE__, []), [:plug, :allow_private])
  end
end
