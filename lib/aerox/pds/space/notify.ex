defmodule Aerox.PDS.Space.Notify do
  @moduledoc """
  Outbound Spaces notifications (DESIGN §12.5 R9, §21.6): `notifyWrite` from
  a writer's PDS to the space host, its fan-out from the space host to
  registered syncers, and `notifySpaceDeleted`. Each is an Oban job on the
  PDS instance's `:spaces` queue, retried with back-off and discarded
  (dead-lettered) after `max_attempts` — upstream fires them best-effort
  and forgets.

  Every delivery is a service JWT (`Aerox.Auth.ServiceJWT`) signed with the
  issuing account's key: `iss` the writer (or the authority for fan-out and
  deletion), `aud` the recipient's identifier — the owner DID for the space
  host, the registered *service identifier* (e.g. `did:web:app#bulletin`)
  for a syncer — and `lxm` the method.
  """
  alias Aerox.PDS.Accounts
  alias Aerox.PDS.Space.{Spaces, Uri}

  @notify_deleted "com.atproto.space.notifySpaceDeleted"

  @doc "The writer side of `notifyWrite` (upstream `fireNotifyWrite`): enqueue delivery to the space host."
  @spec fire_write(String.t(), String.t(), String.t()) :: {:ok, Oban.Job.t()} | {:error, term}
  def fire_write(space, writer_did, rev),
    do:
      Oban.insert(
        Aerox.PDS.Oban,
        __MODULE__.NotifyWrite.new(%{space: space, repo: writer_did, rev: rev})
      )

  @doc "The space host's fan-out of a write to its subscribers."
  @spec fan_out_write(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, Oban.Job.t()} | {:error, term}
  def fan_out_write(owner, space, writer_did, rev),
    do:
      Oban.insert(
        Aerox.PDS.Oban,
        __MODULE__.FanOut.new(%{owner: owner, space: space, repo: writer_did, rev: rev})
      )

  @doc "`notifySpaceDeleted` to every member's PDS and every subscriber."
  @spec fire_space_deleted(String.t(), String.t(), [String.t()], [map]) :: :ok
  def fire_space_deleted(owner, space, member_dids, targets) do
    for did <- member_dids, did != owner do
      # the endpoint is resolved at delivery time (the member's PDS)
      Oban.insert(
        Aerox.PDS.Oban,
        __MODULE__.Deliver.new(%{
          iss: owner,
          aud: did,
          lxm: @notify_deleted,
          body: %{space: space}
        })
      )
    end

    for t <- targets do
      Oban.insert(
        Aerox.PDS.Oban,
        __MODULE__.Deliver.new(%{
          iss: owner,
          aud: t.service,
          url: xrpc_url(t.endpoint, @notify_deleted),
          lxm: @notify_deleted,
          body: %{space: space}
        })
      )
    end

    :ok
  end

  @doc """
  The delivery endpoint of a service identifier: `did#fragment` → that
  service entry of the DID document; a bare DID → its `#atproto_pds`.
  """
  @spec resolve_service_endpoint(String.t()) :: {:ok, String.t()} | {:error, term}
  def resolve_service_endpoint(identifier) do
    {did, fragment} =
      case String.split(identifier, "#", parts: 2) do
        [did, frag] -> {did, "#" <> frag}
        [did] -> {did, nil}
      end

    with {:ok, doc} <- Aerox.Identity.resolve_did(Aerox.PDS.Identity, did) do
      endpoint =
        if fragment,
          do: Aerox.ATProto.Identity.service_endpoint(doc, fragment),
          else: Aerox.ATProto.Identity.pds_endpoint(doc)

      if is_binary(endpoint), do: {:ok, endpoint}, else: {:error, :service_not_resolvable}
    end
  end

  @doc false
  def xrpc_url(endpoint, lxm), do: String.trim_trailing(endpoint, "/") <> "/xrpc/" <> lxm

  @doc "Signs and POSTs one XRPC procedure with service auth. `{:ok, status}` for 2xx."
  @spec deliver(String.t(), String.t(), String.t(), String.t(), map) ::
          {:ok, pos_integer} | {:error, term}
  def deliver(iss, aud, url, lxm, body) do
    case Accounts.signing_keypair(iss) do
      nil ->
        {:error, {:no_keypair, iss}}

      keypair ->
        jwt = Aerox.Auth.ServiceJWT.create(keypair: keypair, iss: iss, aud: aud, lxm: lxm)

        case Aerox.Identity.HTTP.post(url, body, headers: [{"authorization", "Bearer " <> jwt}]) do
          {:ok, status, _headers, _body} when status in 200..299 -> {:ok, status}
          {:ok, status, _headers, resp} -> {:error, {:http, status, String.slice(resp, 0, 200)}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defmodule NotifyWrite do
    @moduledoc "Writer's PDS → space host: `notifyWrite` for one commit."
    use Oban.Worker, queue: :spaces, max_attempts: 5

    @impl true
    def perform(%Oban.Job{args: %{"space" => space, "repo" => repo, "rev" => rev}}) do
      with {:ok, %{did: owner}} <- Uri.parse(space),
           {:ok, endpoint} <- Aerox.PDS.Space.Notify.resolve_service_endpoint(owner),
           {:ok, _} <-
             Aerox.PDS.Space.Notify.deliver(
               repo,
               owner,
               Aerox.PDS.Space.Notify.xrpc_url(endpoint, "com.atproto.space.notifyWrite"),
               "com.atproto.space.notifyWrite",
               %{space: space, repo: repo, rev: rev}
             ) do
        :ok
      end
    end
  end

  defmodule FanOut do
    @moduledoc "Space host → subscribers: one `Deliver` per registered service."
    use Oban.Worker, queue: :spaces, max_attempts: 3

    @impl true
    def perform(%Oban.Job{
          args: %{"owner" => owner, "space" => space, "repo" => repo, "rev" => rev}
        }) do
      jobs =
        for t <- Spaces.notify_targets(owner, space) do
          Aerox.PDS.Space.Notify.Deliver.new(%{
            iss: owner,
            aud: t.service,
            url: Aerox.PDS.Space.Notify.xrpc_url(t.endpoint, "com.atproto.space.notifyWrite"),
            lxm: "com.atproto.space.notifyWrite",
            body: %{space: space, repo: repo, rev: rev}
          })
        end

      if jobs != [], do: Oban.insert_all(Aerox.PDS.Oban, jobs)
      :ok
    end
  end

  defmodule Deliver do
    @moduledoc "One signed HTTP delivery; retried with back-off, discarded after `max_attempts`."
    use Oban.Worker, queue: :spaces, max_attempts: 5

    @impl true
    def perform(%Oban.Job{
          args: %{"iss" => iss, "aud" => aud, "lxm" => lxm, "body" => body} = args
        }) do
      with {:ok, url} <- url(args, aud, lxm),
           {:ok, _} <- Aerox.PDS.Space.Notify.deliver(iss, aud, url, lxm, body) do
        :ok
      end
    end

    defp url(%{"url" => url}, _aud, _lxm) when is_binary(url), do: {:ok, url}

    defp url(_args, aud, lxm) do
      with {:ok, endpoint} <- Aerox.PDS.Space.Notify.resolve_service_endpoint(aud),
           do: {:ok, Aerox.PDS.Space.Notify.xrpc_url(endpoint, lxm)}
    end
  end
end
