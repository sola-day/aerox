defmodule AeroxWeb.PDS.SpaceHelpers do
  @moduledoc "Auth and lookup helpers shared by the `com.atproto.space.*` and `com.atproto.simplespace.*` controllers."
  import AeroxWeb.XRPC
  alias Aerox.PDS.{Accounts, Config}
  alias Aerox.PDS.Space.Uri
  alias AeroxWeb.XRPC.Error

  @doc "The feature flag: `config :aerox, Aerox.PDS.Space, enabled: true`."
  def space_enabled?, do: Application.get_env(:aerox, Aerox.PDS.Space, [])[:enabled] == true

  @doc "Parses a space URI or raises InvalidRequest."
  def space!(uri) do
    case Uri.parse(uri) do
      {:ok, parsed} -> parsed
      {:error, msg} -> raise Error.invalid_request("Invalid space URI: #{msg}")
    end
  end

  @doc "Two space URIs name the same space (either wire form)."
  def same_space?(a, b) do
    with {:ok, pa} <- Uri.parse(a), {:ok, pb} <- Uri.parse(b) do
      {pa.did, pa.type, pa.skey} == {pb.did, pb.type, pb.skey}
    else
      _ -> false
    end
  end

  @doc "Upstream `assertSpaceScope`: OAuth sessions need a matching `space:` scope."
  def assert_space_scope!(conn, parsed, action, collection \\ nil) do
    target = %{type: parsed.type, did: parsed.did, skey: parsed.skey, action: action}
    target = if collection, do: Map.put(target, :collection, collection), else: target
    authorize_oauth!(conn, :space, target)
  end

  @doc """
  Repo-host reads: a session with read scope, or a space credential for
  this very space (upstream `authorizationOrSpaceCredential`).
  """
  def reader_auth!(conn, parsed) do
    case require_auth!(conn, kinds: [:access, :space_credential]) do
      %{type: :space_credential, space: cred_space} = auth ->
        if same_space?(cred_space, parsed.space),
          do: auth,
          else: raise(Error.invalid_request("Credential space mismatch"))

      auth ->
        assert_space_scope!(conn, parsed, "read")
        auth
    end
  end

  @doc "The session's DID, which must be `repo` (upstream: 'repo must match authenticated user')."
  def writer!(conn, repo) do
    %{did: did} = require_auth!(conn)
    if repo != did, do: raise(Error.forbidden("repo must match authenticated user"))
    did
  end

  @doc "An account hosted here whose repo may be read (RepoNotFound / RepoTakendown / RepoDeactivated)."
  def repo_account!(did) do
    account =
      Accounts.get_account(did, include_deactivated: true, include_taken_down: true) ||
        raise(Error.invalid_request("Could not find repo: #{did}", "RepoNotFound"))

    cond do
      account.takedown_ref ->
        raise Error.invalid_request("Repo has been takendown: #{did}", "RepoTakendown")

      account.deactivated_at ->
        raise Error.invalid_request("Repo has been deactivated: #{did}", "RepoDeactivated")

      true ->
        account
    end
  end

  @doc "The space host: the authority must be an account here with a live space row."
  def hosted_space!(parsed) do
    with %{} <- Accounts.get_account(parsed.did),
         %{deleted_at: nil} = space <- Aerox.PDS.Space.Spaces.get(parsed.did, parsed.space) do
      space
    else
      %{deleted_at: _} -> raise Error.invalid_request("Space has been deleted", "SpaceDeleted")
      _ -> raise Error.invalid_request("Space not found", "SpaceNotFound")
    end
  end

  @doc "The OAuth client id an app acted with (`unknown` for legacy sessions, as upstream)."
  def client_id(%{client_id: id}) when is_binary(id), do: id
  def client_id(_), do: "unknown"

  @doc "A service-auth audience acceptable for a notification addressed to `did`."
  def notify_audience_ok?(aud, did), do: aud in [did, Config.service_did()]

  @defs "com.atproto.simplespace.defs"

  @doc "The `appAccess` union for a space row."
  def app_access_lex(%{app_access_mode: "allowList", app_exceptions: allowed}),
    do: %{"$type" => @defs <> "#allowList", "allowed" => allowed}

  def app_access_lex(_), do: %{"$type" => @defs <> "#open"}

  @doc "The `policy` union for a space row (alpha `getSpace`)."
  def policy_lex(%{mint_policy: "public"}), do: %{"$type" => @defs <> "#publicPolicy"}

  def policy_lex(%{mint_policy: "managing-app", managing_app: app}) when is_binary(app),
    do: %{"$type" => @defs <> "#managingAppPolicy", "managingApp" => app}

  def policy_lex(_), do: %{"$type" => @defs <> "#memberListPolicy"}
end

defmodule AeroxWeb.PDS.SpaceController do
  @moduledoc """
  `com.atproto.space.*` (DESIGN §12.5): the PDS plays all three roles.

  * **PDS role** (the writer's home; session or OAuth with `space:` scopes,
    upstream `assertSpaceScope`): `getDelegationToken`, `createRecord`,
    `putRecord`, `deleteRecord`, `applyWrites`, `listSpaces`.
  * **Repo-host role** (session *or* a space credential for this space):
    `getRecord`, `listRecords`, `getRepoState`, `listRepoOps`, `getRepo`,
    `getBlob`.
  * **Space-host role** (the authority's PDS): `getSpaceCredential` (member
    grant), `getSpace`, `listRepos`, `registerNotify` (space credential),
    `notifyWrite` / `notifySpaceDeleted` (service auth).

  Space writes never touch the sequencer (DESIGN §12.3): this module has no
  reference to it.
  """
  use AeroxWeb, :controller
  use AeroxWeb.Plugs.XRPCError
  import AeroxWeb.XRPC
  import AeroxWeb.PDS.SpaceHelpers
  alias Aerox.ATProto.{CID, Data}
  alias Aerox.PDS.{Accounts, Blobs, Clock}
  alias Aerox.PDS.Space.{Credentials, Notify, Policy, Records, Spaces, Uri}
  alias AeroxWeb.Plugs.RateLimit
  alias AeroxWeb.XRPC.Error

  plug :enabled

  # the feature flag (`config :aerox, Aerox.PDS.Space, enabled:`): 501 when off
  defp enabled(conn, _) do
    if space_enabled?(),
      do: conn,
      else: AeroxWeb.Plugs.XRPCError.render(conn, Error.not_implemented())
  end

  # ================================================================ PDS role

  def get_delegation_token(conn, _) do
    params = params!(conn, "com.atproto.space.getDelegationToken")
    auth = require_auth!(conn)
    parsed = space!(params["space"])
    # the user's PDS only attests identity, gated by the scope; the authority
    # decides (upstream getMemberGrant / the alpha's delegation token)
    assert_space_scope!(conn, parsed, "read")

    keypair =
      Accounts.signing_keypair(auth.did) || raise(Error.auth_required("Account not found"))

    token =
      Credentials.create_delegation(
        %{iss: auth.did, space: parsed.space, aud: Credentials.space_host_aud(parsed.did)},
        keypair
      )

    respond(conn, %{"token" => token})
  end

  def create_record(conn, _) do
    input = input!(conn, "com.atproto.space.createRecord")
    parsed = space!(input["space"])
    did = writer!(conn, input["repo"])
    collection = input["collection"]
    assert_space_scope!(conn, parsed, "create", collection)
    rkey = input["rkey"] || Clock.next_tid()

    with {:ok, conn} <- RateLimit.consume(conn, :repo_write, 3) do
      %{writes: [w]} =
        write!(did, parsed.space, [
          %{action: :create, collection: collection, rkey: rkey, record: input["record"]}
        ])

      respond(conn, %{
        "uri" => Uri.record_uri(parsed.space, did, collection, rkey),
        "cid" => CID.to_string(w.cid)
      })
    end
  end

  def put_record(conn, _) do
    input = input!(conn, "com.atproto.space.putRecord")
    parsed = space!(input["space"])
    did = writer!(conn, input["repo"])
    collection = input["collection"]
    rkey = input["rkey"]
    assert_space_scope!(conn, parsed, "create", collection)
    assert_space_scope!(conn, parsed, "update", collection)

    with {:ok, conn} <- RateLimit.consume(conn, :repo_write, 2) do
      action =
        if Records.has_record?(did, parsed.space, collection, rkey), do: :update, else: :create

      %{writes: [w]} =
        write!(did, parsed.space, [
          %{action: action, collection: collection, rkey: rkey, record: input["record"]}
        ])

      respond(conn, %{
        "uri" => Uri.record_uri(parsed.space, did, collection, rkey),
        "cid" => CID.to_string(w.cid)
      })
    end
  end

  def delete_record(conn, _) do
    input = input!(conn, "com.atproto.space.deleteRecord")
    parsed = space!(input["space"])
    did = writer!(conn, input["repo"])
    collection = input["collection"]
    rkey = input["rkey"]
    assert_space_scope!(conn, parsed, "delete", collection)

    with {:ok, conn} <- RateLimit.consume(conn, :repo_write, 1) do
      # alpha: succeeds whether or not the record was present
      if Records.has_record?(did, parsed.space, collection, rkey),
        do:
          write!(did, parsed.space, [
            %{action: :delete, collection: collection, rkey: rkey, record: nil}
          ])

      respond(conn, %{})
    end
  end

  def apply_writes(conn, _) do
    input = input!(conn, "com.atproto.space.applyWrites")
    parsed = space!(input["space"])
    did = writer!(conn, input["repo"])
    writes = input["writes"] || []
    if length(writes) > 200, do: raise(Error.invalid_request("Too many writes. Max: 200"))

    ops =
      Enum.map(writes, fn w ->
        case w["$type"] do
          "com.atproto.space.applyWrites#create" ->
            %{
              action: :create,
              collection: w["collection"],
              rkey: w["rkey"] || Clock.next_tid(),
              record: w["value"]
            }

          "com.atproto.space.applyWrites#update" ->
            %{action: :update, collection: w["collection"], rkey: w["rkey"], record: w["value"]}

          "com.atproto.space.applyWrites#delete" ->
            %{action: :delete, collection: w["collection"], rkey: w["rkey"], record: nil}

          other ->
            raise Error.invalid_request("Unknown write type: #{inspect(other)}")
        end
      end)

    for op <- ops, do: assert_space_scope!(conn, parsed, Atom.to_string(op.action), op.collection)

    points =
      Enum.reduce(ops, 0, fn %{action: a}, n -> n + %{create: 3, update: 2, delete: 1}[a] end)

    with {:ok, conn} <- RateLimit.consume(conn, :repo_write, max(points, 1)) do
      %{writes: prepared} = write!(did, parsed.space, ops)

      results =
        Enum.map(prepared, fn
          %{action: :delete} ->
            %{"$type" => "com.atproto.space.applyWrites#deleteResult"}

          %{action: action} = w ->
            %{
              "$type" =>
                "com.atproto.space.applyWrites##{if action == :create, do: "createResult", else: "updateResult"}",
              "uri" => Uri.record_uri(parsed.space, did, w.collection, w.rkey),
              "cid" => CID.to_string(w.cid)
            }
        end)

      respond(conn, %{"results" => results})
    end
  end

  def list_spaces(conn, _) do
    params = params!(conn, "com.atproto.space.listSpaces")
    %{did: did} = require_auth!(conn)

    authorize_oauth!(conn, :space, %{
      type: params["type"] || "*",
      did: params["did"] || "*",
      skey: "*",
      action: "read"
    })

    spaces =
      Spaces.list(did,
        limit: params["limit"] || 50,
        cursor: params["cursor"],
        type: params["type"],
        owner: params["did"]
      )

    last = List.last(spaces)

    respond(
      conn,
      %{"spaces" => Enum.map(spaces, &%{"uri" => &1.uri, "isOwner" => &1.is_owner})}
      |> then(&if(last, do: Map.put(&1, "cursor", last.uri), else: &1))
    )
  end

  # the write path: records + oplog + state in one transaction, the blobs the
  # records reference promoted, then notifyWrite queued (DESIGN §12.3, §21.6)
  defp write!(did, space, ops) do
    case Records.write(did, space, ops) do
      {:ok, %{rev: rev, writes: prepared} = result} ->
        blobs = prepared |> Enum.flat_map(&if(&1.record, do: Data.blob_refs(&1.record), else: []))

        case Blobs.process_write_blobs(did, blobs) do
          :ok ->
            :ok

          {:error, {:blob_not_found, cid}} ->
            raise Error.invalid_request("Could not find blob: #{cid}", "BlobNotFound")

          {:error, {:invalid_blob, msg}} ->
            raise Error.invalid_request(msg, "InvalidBlob")
        end

        {:ok, _} = Notify.fire_write(space, did, rev)
        result

      {:error, {:record_already_exists, collection, rkey}} ->
        raise Error.invalid_request(
                "Record already exists: #{collection}/#{rkey}",
                "RecordAlreadyExists"
              )

      {:error, {:record_not_found, collection, rkey}} ->
        raise Error.invalid_request(
                "Could not find record: #{collection}/#{rkey}",
                "RecordNotFound"
              )

      {:error, other} ->
        raise Error.invalid_request("Write failed: #{inspect(other)}")
    end
  end

  # ========================================================== repo-host role

  def get_record(conn, _) do
    params = params!(conn, "com.atproto.space.getRecord")
    parsed = space!(params["space"])
    reader_auth!(conn, parsed)
    account = repo_account!(params["repo"])
    space_live!(account.did, parsed)

    case Records.get_record(account.did, parsed.space, params["collection"], params["rkey"]) do
      {:ok, %{cid: cid, value: value}} ->
        respond(conn, %{
          "uri" =>
            Uri.record_uri(parsed.space, account.did, params["collection"], params["rkey"]),
          "cid" => cid,
          "value" => value
        })

      {:error, :not_found} ->
        raise Error.invalid_request(
                "Could not locate record: #{parsed.space}/#{params["collection"]}/#{params["rkey"]}",
                "RecordNotFound"
              )
    end
  end

  def list_records(conn, _) do
    params = params!(conn, "com.atproto.space.listRecords")
    parsed = space!(params["space"])
    reader_auth!(conn, parsed)
    account = repo_account!(params["repo"])
    space_live!(account.did, parsed)

    %{records: records, cursor: cursor} =
      Records.list_records(account.did, parsed.space,
        limit: params["limit"] || 50,
        cursor: params["cursor"],
        reverse: params["reverse"] || false,
        collection: params["collection"]
      )

    body = %{
      "records" =>
        Enum.map(records, &%{"collection" => &1.collection, "rkey" => &1.rkey, "cid" => &1.cid})
    }

    respond(conn, if(cursor, do: Map.put(body, "cursor", cursor), else: body))
  end

  def get_repo_state(conn, _) do
    params = params!(conn, "com.atproto.space.getRepoState")
    parsed = space!(params["space"])
    reader_auth!(conn, parsed)
    account = repo_account!(params["repo"])
    space_live!(account.did, parsed)

    case Records.signed_commit(account.did, parsed.space, :records) do
      nil -> respond(conn, %{})
      commit -> respond(conn, %{"commit" => Records.commit_lex(commit)})
    end
  end

  def list_repo_ops(conn, _) do
    params = params!(conn, "com.atproto.space.listRepoOps")
    parsed = space!(params["space"])
    reader_auth!(conn, parsed)
    account = repo_account!(params["repo"])
    space_live!(account.did, parsed)

    # alpha lexicon additions (bulletin): `cursor`, `excludeValues`
    %{ops: ops, commit: commit, cursor: cursor} =
      Records.oplog(account.did, parsed.space,
        since: params["since"],
        cursor: conn.query_params["cursor"],
        limit: params["limit"] || 100,
        exclude_values: conn.query_params["excludeValues"] == "true"
      )

    body = %{
      "ops" =>
        Enum.map(ops, fn op ->
          %{
            "rev" => op.rev,
            "collection" => op.collection,
            "rkey" => op.rkey,
            "cid" => op.cid,
            "prev" => op.prev
          }
          |> then(&if(Map.has_key?(op, :value), do: Map.put(&1, "value", op.value), else: &1))
        end)
    }

    body = if commit, do: Map.put(body, "commit", Records.commit_lex(commit)), else: body
    body = if cursor, do: Map.put(body, "cursor", cursor), else: body
    respond(conn, body)
  end

  # not in the vendored lexicons (DESIGN §12.5, bulletin `recoverRepo`): the
  # two-root CAR of the whole repo
  def get_repo(conn, _) do
    space =
      conn.query_params["space"] ||
        raise(Error.invalid_request("Error: Params must have the property \"space\""))

    repo =
      conn.query_params["repo"] ||
        raise(Error.invalid_request("Error: Params must have the property \"repo\""))

    parsed = space!(space)
    reader_auth!(conn, parsed)
    account = repo_account!(repo)
    space_live!(account.did, parsed)

    case Records.export_car(account.did, parsed.space) do
      nil ->
        raise Error.invalid_request("Repo has no commits in this space", "RepoNotFound")

      car ->
        conn |> put_resp_content_type("application/vnd.ipld.car", nil) |> send_resp(200, car)
    end
  end

  def get_blob(conn, _) do
    params = params!(conn, "com.atproto.space.getBlob")
    parsed = space!(params["space"])
    reader_auth!(conn, parsed)
    account = repo_account!(params["repo"])

    cid =
      case CID.parse(params["cid"]) do
        {:ok, c} -> c
        _ -> raise Error.invalid_request("Invalid CID")
      end

    case Blobs.get(account.did, cid) do
      {:error, :not_found} ->
        raise Error.invalid_request("Blob not found", "BlobNotFound")

      {:ok, %{size: size, mime_type: mime, stream: stream}} ->
        conn =
          conn
          |> put_resp_header("content-length", Integer.to_string(size))
          |> put_resp_header("x-content-type-options", "nosniff")
          |> put_resp_header("content-disposition", ~s(attachment; filename="#{params["cid"]}"))
          |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
          |> put_resp_content_type(mime || "application/octet-stream", nil)
          |> send_chunked(200)

        Enum.reduce_while(stream, conn, fn chunk, conn ->
          case chunk(conn, chunk) do
            {:ok, conn} -> {:cont, conn}
            {:error, _} -> {:halt, conn}
          end
        end)
    end
  end

  # a repo host refuses a space its account has tombstoned (notifySpaceDeleted)
  defp space_live!(did, parsed) do
    case Spaces.get(did, parsed.space) do
      %{deleted_at: at} when not is_nil(at) ->
        raise Error.invalid_request("Space not found", "SpaceNotFound")

      _ ->
        :ok
    end
  end

  # ========================================================= space-host role

  def get_space_credential(conn, _) do
    input = input!(conn, "com.atproto.space.getSpaceCredential")
    delegation = require_auth!(conn, kinds: [:delegation])
    parsed = space!(input["space"])

    unless same_space?(delegation.sub, parsed.space),
      do:
        raise(
          Error.invalid_request(
            "token subject does not match the requested space",
            "InvalidDelegationToken"
          )
        )

    if delegation.aud != Credentials.space_host_aud(parsed.did),
      do:
        raise(
          Error.invalid_request(
            "token audience does not match this space host",
            "InvalidDelegationToken"
          )
        )

    space = hosted_space!(parsed)

    # the app's identity comes only from a client attestation (the alpha
    # tokens carry no client id); the user's PDS session is not involved
    client_id = client_attestation!(input["clientAttestation"], parsed.did)

    case Policy.authorize_user(space, delegation.did, client_id) do
      :ok ->
        :ok

      {:error, :user_not_authorized} ->
        raise Error.forbidden("User not authorized for this space", "UserNotAuthorized")

      {:error, :managing_app_unreachable} ->
        raise Error.forbidden("Could not verify access with the managing app", "NotAuthorized")
    end

    if Policy.authorize_app(space, client_id) != :ok,
      do:
        raise(
          Error.forbidden("Application not permitted to access this space", "AppNotAuthorized")
        )

    # the credential is bound to the DPoP key that signed this request
    jkt =
      case Aerox.Auth.DPoP.verify(
             conn |> get_req_header("dpop") |> List.first(),
             conn.method,
             Aerox.PDS.Config.public_url() <> conn.request_path,
             nonces: false
           ) do
        {:ok, %{jkt: jkt}} -> jkt
        {:ok, nil} -> raise Error.auth_required("DPoP proof required", "InvalidToken")
        {:error, {:invalid_dpop_proof, msg}} -> raise Error.auth_required(msg, "InvalidToken")
        {:error, _} -> raise Error.auth_required("Invalid DPoP proof", "InvalidToken")
      end

    keypair = Accounts.signing_keypair(parsed.did)

    credential =
      Credentials.create_credential(%{iss: parsed.did, space: parsed.space, jkt: jkt}, keypair)

    respond(conn, %{"credential" => credential})
  end

  # `clientAttestation`: `iss == sub == client_id`, `aud` this space host,
  # signed by a key in the client's published JWKS (its OAuth metadata)
  defp client_attestation!(nil, _space_did), do: "unknown"

  defp client_attestation!(token, space_did) do
    invalid = fn msg -> raise(Error.invalid_request(msg, "InvalidClientAttestation")) end

    with {:ok, _header, %{"iss" => client_id}} when is_binary(client_id) <-
           Credentials.peek(token),
         {:ok, %{jwks: %{"keys" => _} = jwks}} <- Aerox.PDS.OAuth.Clients.get(client_id),
         {:ok, %{client_id: client_id}} <-
           Credentials.verify_attestation(token, jwks, aud: Credentials.space_host_aud(space_did)) do
      client_id
    else
      {:ok, %{jwks: _}} -> invalid.("the client publishes no JWKS")
      {:error, {_name, msg}} when is_binary(msg) -> invalid.(msg)
      _ -> invalid.("could not verify the client attestation")
    end
  end

  def get_space(conn, _) do
    params = params!(conn, "com.atproto.space.getSpace")
    parsed = space!(params["space"])
    reader_auth!(conn, parsed)
    space = hosted_space!(parsed)

    respond(conn, %{
      "uri" => space.uri,
      "config" =>
        Map.merge(
          %{
            "$type" => "com.atproto.simplespace.defs#spaceConfig",
            "mintPolicy" => space.mint_policy,
            "appAccess" => app_access_lex(space)
          },
          if(space.managing_app, do: %{"managingApp" => space.managing_app}, else: %{})
        )
    })
  end

  def list_repos(conn, _) do
    params = params!(conn, "com.atproto.space.listRepos")
    parsed = space!(params["space"])
    reader_auth!(conn, parsed)
    _ = hosted_space!(parsed)

    writers =
      Spaces.list_writers(parsed.did, parsed.space,
        limit: params["limit"] || 100,
        cursor: params["cursor"]
      )

    repos =
      Enum.map(writers, fn w ->
        %{"did" => w.did, "rev" => w.rev}
        |> then(&if(w.hash, do: Map.put(&1, "hash", Aerox.ATProto.Bytes.new(w.hash)), else: &1))
      end)

    last = List.last(writers)
    body = %{"repos" => repos}
    respond(conn, if(last, do: Map.put(body, "cursor", last.did), else: body))
  end

  def register_notify(conn, _) do
    # the vendored lexicon takes `endpoint` (+ optional `repo`); the alpha
    # (bulletin) a `service` identifier resolved through its DID document
    body = conn.body_params

    parsed =
      space!(
        body["space"] ||
          raise(Error.invalid_request("Error: Input must have the property \"space\""))
      )

    auth = require_auth!(conn, kinds: [:space_credential])

    unless same_space?(auth.space, parsed.space),
      do: raise(Error.invalid_request("Credential space mismatch"))

    _ = hosted_space!(parsed)

    {service, endpoint} =
      case body do
        %{"service" => service} when is_binary(service) and service != "" ->
          case Notify.resolve_service_endpoint(service) do
            {:ok, endpoint} ->
              {service, endpoint}

            {:error, _} ->
              raise Error.invalid_request(
                      "Could not resolve the service endpoint",
                      "ServiceNotResolvable"
                    )
          end

        %{"endpoint" => endpoint} when is_binary(endpoint) and endpoint != "" ->
          unless Aerox.ATProto.Syntax.valid_uri?(endpoint),
            do: raise(Error.invalid_request("Error: Input/endpoint must be a uri"))

          # keyed by the credential's DPoP key (one registration per holder + endpoint)
          {auth.jkt <> "@" <> endpoint, endpoint}

        _ ->
          raise Error.invalid_request("Error: Input must have the property \"service\"")
      end

    expires = Spaces.register_notify(parsed.did, parsed.space, service, endpoint)
    respond(conn, %{"expiresAt" => DateTime.to_iso8601(expires)})
  end

  def notify_write(conn, _) do
    input = input!(conn, "com.atproto.space.notifyWrite")
    auth = require_auth!(conn, kinds: [:service])
    parsed = space!(input["space"])
    repo = input["repo"]

    # the JWT is signed by the writer: iss is the authoritative caller
    if auth.did != repo,
      do: raise(Error.forbidden("notifyWrite iss does not match claimed writer"))

    unless notify_audience_ok?(auth[:aud], parsed.did),
      do: raise(Error.auth_required("jwt audience does not match service did", "BadJwtAudience"))

    # only the space host has the fan-out state; elsewhere this is a no-op
    case Accounts.get_account(parsed.did) && Spaces.get(parsed.did, parsed.space) do
      %{deleted_at: nil, is_owner: true} = space ->
        if space.mint_policy == "member-list" and
             not Spaces.member?(parsed.did, parsed.space, repo),
           do: raise(Error.forbidden("notifyWrite writer is not a member of the space"))

        hash =
          case Accounts.get_account(repo) && Records.state(repo, parsed.space) do
            %{set_hash: h} when is_binary(h) -> Aerox.ATProto.Space.LtHash.digest(h)
            _ -> nil
          end

        :ok = Spaces.record_writer(parsed.did, parsed.space, repo, input["rev"], hash)
        {:ok, _} = Notify.fan_out_write(parsed.did, parsed.space, repo, input["rev"])
        send_resp(conn, 200, "")

      %{deleted_at: at} when not is_nil(at) ->
        raise Error.invalid_request("Space not found", "SpaceNotFound")

      _ ->
        send_resp(conn, 200, "")
    end
  end

  def notify_space_deleted(conn, _) do
    input = input!(conn, "com.atproto.space.notifySpaceDeleted")
    auth = require_auth!(conn, kinds: [:service])
    parsed = space!(input["space"])

    if auth.did != parsed.did,
      do: raise(Error.auth_required("JWT issuer must be the space DID", "UntrustedIss"))

    # best effort: the recipient (aud) must be an account here holding the space
    with aud when is_binary(aud) <- auth[:aud],
         %{} <- Accounts.get_account(aud),
         %{deleted_at: nil} = space <- Spaces.get(aud, parsed.space) do
      Spaces.mark_deleted(space)
    end

    send_resp(conn, 200, "")
  end
end
