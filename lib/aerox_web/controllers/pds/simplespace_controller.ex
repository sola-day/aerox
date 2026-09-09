defmodule AeroxWeb.PDS.SimplespaceController do
  @moduledoc """
  `com.atproto.simplespace.*` (DESIGN §12.5): the mandatory management
  handler on the space host — `createSpace`, `updateSpace`, `deleteSpace`,
  `getSpace`, `addMember`, `removeMember`, `listMembers`. Every call is the
  owner's session (OAuth needs a `space:…?action=manage` scope, upstream
  `assertSpaceScope`), except `getSpace`, which a member's space credential
  may also read. `checkUserAccess` is served by the managing app, not here.

  `createSpace` accepts both the vendored shape (`did`, `type`, `skey`,
  `config`) and the alpha's (`type`, `skey`, `policy`, `appAccess` unions,
  as `bulletin` sends); `getSpace` answers in the alpha's shape.
  """
  use AeroxWeb, :controller
  use AeroxWeb.Plugs.XRPCError
  import AeroxWeb.XRPC
  import AeroxWeb.PDS.SpaceHelpers
  alias Aerox.ATProto.Syntax
  alias Aerox.PDS.{Accounts, Clock}
  alias Aerox.PDS.Space.{Notify, Spaces, Uri}
  alias AeroxWeb.XRPC.Error

  @defs "com.atproto.simplespace.defs"

  plug :enabled

  # the feature flag (`config :aerox, Aerox.PDS.Space, enabled:`): 501 when off
  defp enabled(conn, _) do
    if space_enabled?(),
      do: conn,
      else: AeroxWeb.Plugs.XRPCError.render(conn, Error.not_implemented())
  end

  def create_space(conn, _) do
    %{did: did} = require_auth!(conn)
    body = conn.body_params
    type = body["type"]

    unless is_binary(type) and Syntax.valid_nsid?(type),
      do: raise(Error.invalid_request("Invalid space type", "InvalidType"))

    space_did = body["did"] || did

    if space_did != did,
      do: raise(Error.invalid_request("The space must be anchored on the authenticated DID"))

    skey =
      case body["skey"] do
        nil ->
          Clock.next_tid()

        s when is_binary(s) and byte_size(s) <= 512 ->
          if Syntax.valid_record_key?(s),
            do: s,
            else: raise(Error.invalid_request("Error: Input/skey must be a valid record key"))

        _ ->
          raise Error.invalid_request("Error: Input/skey must be a string")
      end

    uri = Uri.format(space_did, type, skey, :at)
    parsed = space!(uri)
    assert_space_scope!(conn, parsed, "manage")
    config = config_from(body)

    case Spaces.create(did, uri, true, config) do
      {:ok, space} ->
        respond(conn, %{"uri" => space.uri})

      {:error, :already_exists} ->
        raise Error.invalid_request("Space already exists", "SpaceAlreadyExists")
    end
  end

  # the vendored `config` ref or the alpha's top-level `policy`/`appAccess`
  defp config_from(body) do
    base = Spaces.default_config()
    cfg = body["config"] || body

    policy =
      case cfg["policy"] do
        %{"$type" => @defs <> "#publicPolicy"} ->
          %{mint_policy: "public", is_public: true}

        %{"$type" => @defs <> "#memberListPolicy"} ->
          %{mint_policy: "member-list"}

        %{"$type" => @defs <> "#managingAppPolicy", "managingApp" => app} when is_binary(app) ->
          %{mint_policy: "managing-app", managing_app: app}

        %{"$type" => _} ->
          raise Error.invalid_request("Unsupported policy", "UnsupportedPolicy")

        _ ->
          case cfg["mintPolicy"] do
            nil ->
              %{}

            p when p in ["public", "member-list", "managing-app"] ->
              %{mint_policy: p, is_public: p == "public"}

            _ ->
              raise Error.invalid_request("Unsupported policy", "UnsupportedPolicy")
          end
      end

    managing =
      case cfg["managingApp"] do
        app when is_binary(app) and app != "" -> %{managing_app: app}
        _ -> %{}
      end

    app_access =
      case cfg["appAccess"] do
        nil -> %{}
        access -> app_access_from(access)
      end

    base |> Map.merge(managing) |> Map.merge(policy) |> Map.merge(app_access)
  end

  defp app_access_from(%{"$type" => @defs <> "#open"}),
    do: %{app_access_mode: "open", app_exceptions: []}

  defp app_access_from(%{"$type" => @defs <> "#allowList", "allowed" => allowed})
       when is_list(allowed) do
    unless Enum.all?(allowed, &is_binary/1),
      do: raise(Error.invalid_request("Error: Input/appAccess/allowed must be strings"))

    %{app_access_mode: "allowList", app_exceptions: allowed}
  end

  defp app_access_from(_),
    do: raise(Error.invalid_request("Unsupported appAccess", "UnsupportedAppAccess"))

  def update_space(conn, _) do
    input = input!(conn, "com.atproto.simplespace.updateSpace")
    {parsed, space} = owner!(conn, input["space"])
    assert_space_scope!(conn, parsed, "manage")

    patch =
      %{}
      |> then(fn p ->
        case input["mintPolicy"] do
          nil -> p
          m when m in ["public", "member-list", "managing-app"] -> Map.put(p, :mint_policy, m)
          _ -> raise Error.invalid_request("Unsupported policy", "UnsupportedPolicy")
        end
      end)
      |> then(fn p ->
        case input["managingApp"] do
          nil -> p
          "" -> Map.put(p, :managing_app, nil)
          app -> Map.put(p, :managing_app, app)
        end
      end)
      |> then(fn p ->
        case input["appAccess"] do
          nil -> p
          access -> Map.merge(p, app_access_from(access))
        end
      end)

    _ = Spaces.update_config(space, patch)
    send_resp(conn, 200, "")
  end

  def delete_space(conn, _) do
    input = input!(conn, "com.atproto.simplespace.deleteSpace")
    parsed = space!(input["space"])
    %{did: did} = require_auth!(conn)
    assert_space_scope!(conn, parsed, "manage")
    if parsed.did != did, do: raise(Error.invalid_request("Not the space owner", "NotSpaceOwner"))

    case Spaces.get(did, parsed.space) do
      nil ->
        raise Error.invalid_request("Space not found", "SpaceNotFound")

      %{is_owner: false} ->
        raise Error.invalid_request("Not the space owner", "NotSpaceOwner")

      # idempotent
      %{deleted_at: at} when not is_nil(at) ->
        send_resp(conn, 200, "")

      space ->
        members = Spaces.list_members(did, parsed.space, limit: 10_000) |> Enum.map(& &1.did)
        targets = Spaces.notify_targets(did, parsed.space)
        Spaces.mark_deleted(space)
        Spaces.purge_owner_data(did, parsed.space)
        :ok = Notify.fire_space_deleted(did, parsed.space, members, targets)
        send_resp(conn, 200, "")
    end
  end

  # alpha lexicon (bulletin): `{uri, policy, appAccess}`; session or credential
  def get_space(conn, _) do
    uri =
      conn.query_params["space"] ||
        raise(Error.invalid_request("Error: Params must have the property \"space\""))

    parsed = space!(uri)
    reader_auth!(conn, parsed)
    space = hosted_space!(parsed)

    respond(conn, %{
      "uri" => space.uri,
      "policy" => policy_lex(space),
      "appAccess" => app_access_lex(space)
    })
  end

  def add_member(conn, _) do
    input = input!(conn, "com.atproto.simplespace.addMember")
    {parsed, _space} = owner!(conn, input["space"])
    assert_space_scope!(conn, parsed, "manage")

    case Spaces.add_member(parsed.did, parsed.space, input["did"]) do
      {:ok, _rev} -> send_resp(conn, 200, "")
      {:error, :member_already_exists} -> send_resp(conn, 200, "")
    end
  end

  def remove_member(conn, _) do
    input = input!(conn, "com.atproto.simplespace.removeMember")
    {parsed, _space} = owner!(conn, input["space"])
    assert_space_scope!(conn, parsed, "manage")

    case Spaces.remove_member(parsed.did, parsed.space, input["did"]) do
      {:ok, _rev} -> send_resp(conn, 200, "")
      {:error, :member_not_found} -> send_resp(conn, 200, "")
    end
  end

  def list_members(conn, _) do
    params = params!(conn, "com.atproto.simplespace.listMembers")
    {parsed, _space} = owner!(conn, params["space"])
    assert_space_scope!(conn, parsed, "manage")

    members =
      Spaces.list_members(parsed.did, parsed.space,
        limit: params["limit"] || 100,
        cursor: params["cursor"]
      )

    body = %{"members" => Enum.map(members, &%{"did" => &1.did})}
    last = List.last(members)
    respond(conn, if(last, do: Map.put(body, "cursor", last.did), else: body))
  end

  # the caller must be the space's owner, hosted here, with a live row
  defp owner!(conn, uri) do
    parsed = space!(uri)
    %{did: did} = require_auth!(conn)
    if parsed.did != did, do: raise(Error.invalid_request("Not the space owner", "NotSpaceOwner"))

    _ =
      Accounts.get_account(did) ||
        raise(Error.invalid_request("Space not found", "SpaceNotFound"))

    case Spaces.get(did, parsed.space) do
      %{deleted_at: nil, is_owner: true} = space -> {parsed, space}
      %{deleted_at: nil} -> raise Error.invalid_request("Not the space owner", "NotSpaceOwner")
      _ -> raise Error.invalid_request("Space not found", "SpaceNotFound")
    end
  end
end
