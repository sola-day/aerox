defmodule Aerox.PDS.Space.Spaces do
  @moduledoc """
  Space rows and the space host's member list (DESIGN §12.3, §12.5; upstream
  `actor-store/space/{reader,transactor}.ts` and `space-members.ts`).

  A space row is one account's view of a space: `is_owner` on the authority's
  PDS, `is_member` on a writer's PDS (created lazily on the first write —
  the alpha has no `notifyMembership`). The member list is host-internal
  state: a set of DIDs whose LtHash (element = the DID string, as
  `space-members.ts`) is committed like a repo under the `members` scope.
  """
  import Ecto.Query
  alias Aerox.ATProto.Space.LtHash
  alias Aerox.PDS.{Clock, Repo}

  alias Aerox.PDS.Space.Schema.{
    Space,
    SpaceCredentialRecipient,
    SpaceMember,
    SpaceMemberOplog,
    SpaceMemberState,
    SpaceNotifyRegistration,
    SpaceRepo,
    SpaceWriter
  }

  @type space :: %Space{}

  @doc "The simplespace defaults (createSpace: `mintPolicy 'member-list', appAccess '#open'`)."
  def default_config,
    do: %{
      mint_policy: "member-list",
      managing_app: nil,
      is_public: false,
      app_access_mode: "open",
      app_exceptions: []
    }

  # ---------------------------------------------------------------- spaces

  @doc "The account's row for a space, deleted or not."
  @spec get(String.t(), String.t()) :: space | nil
  def get(did, uri), do: Repo.get_by(Space, did: did, uri: uri)

  @doc "The row unless tombstoned."
  @spec get_active(String.t(), String.t()) :: space | nil
  def get_active(did, uri) do
    case get(did, uri) do
      %Space{deleted_at: nil} = s -> s
      _ -> nil
    end
  end

  @doc """
  Creates a space for `did` (upstream `createSpace`): the space row, its repo
  row and — for the owner — the member state with the owner as first member.
  """
  @spec create(String.t(), String.t(), boolean, map) :: {:ok, space} | {:error, :already_exists}
  def create(did, uri, is_owner, config \\ %{}) do
    cfg = Map.merge(default_config(), config)
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      case get(did, uri) do
        # a deleted space may be created again (alpha createSpace); the
        # tombstone is replaced
        %Space{deleted_at: at} = old when not is_nil(at) ->
          Repo.delete!(old)
          insert_space(did, uri, is_owner, cfg, now)

        %Space{} ->
          Repo.rollback(:already_exists)

        nil ->
          insert_space(did, uri, is_owner, cfg, now)
      end
    end)
  end

  defp insert_space(did, uri, is_owner, cfg, now) do
    space =
      Repo.insert!(%Space{
        did: did,
        uri: uri,
        is_owner: is_owner,
        is_member: true,
        mint_policy: cfg.mint_policy,
        managing_app: cfg.managing_app,
        is_public: cfg.is_public or cfg.mint_policy == "public",
        app_access_mode: cfg.app_access_mode,
        app_exceptions: cfg.app_exceptions,
        created_at: now
      })

    Repo.insert!(%SpaceRepo{did: did, space: uri}, on_conflict: :nothing)

    if is_owner do
      Repo.insert!(%SpaceMemberState{did: did, space: uri}, on_conflict: :nothing)
      {:ok, _} = apply_member_ops(did, uri, [{:add, did}])
    end

    space
  end

  @doc "Ensures a writer's PDS has a (non-owner, member) row for a space it writes to."
  @spec ensure_member_row(String.t(), String.t()) :: space
  def ensure_member_row(did, uri) do
    case get(did, uri) do
      %Space{deleted_at: nil} = s ->
        if s.is_member, do: s, else: s |> Ecto.Changeset.change(is_member: true) |> Repo.update!()

      _ ->
        {:ok, s} = create(did, uri, false)
        s
    end
  end

  @doc "Space config patch (upstream `updateSpaceConfig`); `managing_app: nil` clears."
  @spec update_config(space, map) :: space
  def update_config(%Space{} = space, patch) do
    patch =
      Map.take(patch, [:mint_policy, :managing_app, :is_public, :app_access_mode, :app_exceptions])

    patch =
      case patch do
        %{mint_policy: "public"} -> Map.put(patch, :is_public, true)
        %{mint_policy: _} -> Map.put(patch, :is_public, false)
        _ -> patch
      end

    space |> Ecto.Changeset.change(patch) |> Repo.update!()
  end

  @doc "Tombstones a space row (owner or member side)."
  @spec mark_deleted(space) :: space
  def mark_deleted(%Space{} = space),
    do: space |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update!()

  @doc "Owner-side purge after deletion (upstream `purgeOwnerSpaceData`): members, state, oplog, recipients, registrations, writers."
  @spec purge_owner_data(String.t(), String.t()) :: :ok
  def purge_owner_data(did, uri) do
    for schema <- [
          SpaceMember,
          SpaceMemberState,
          SpaceMemberOplog,
          SpaceCredentialRecipient,
          SpaceNotifyRegistration,
          SpaceWriter
        ] do
      Repo.delete_all(from(r in schema, where: r.did == ^did and r.space == ^uri))
    end

    :ok
  end

  @doc "`listSpaces`: spaces the account owns or has written to, by URI, filtered by type/owner."
  @spec list(String.t(), keyword) :: [space]
  def list(did, opts) do
    limit = Keyword.get(opts, :limit, 50)

    q =
      from(s in Space,
        where: s.did == ^did and is_nil(s.deleted_at) and (s.is_owner or s.is_member),
        order_by: [asc: s.uri],
        limit: ^limit
      )

    q = if c = opts[:cursor], do: where(q, [s], s.uri > ^c), else: q
    rows = Repo.all(q)

    # the URI form varies (ats:// vs at://…/space/…): filter on parsed parts
    Enum.filter(rows, fn s ->
      case Aerox.PDS.Space.Uri.parse(s.uri) do
        {:ok, p} ->
          (is_nil(opts[:type]) or p.type == opts[:type]) and
            (is_nil(opts[:owner]) or p.did == opts[:owner])

        _ ->
          false
      end
    end)
  end

  # --------------------------------------------------------------- members

  @spec member?(String.t(), String.t(), String.t()) :: boolean
  def member?(owner, uri, member_did),
    do:
      Repo.exists?(
        from(m in SpaceMember,
          where: m.did == ^owner and m.space == ^uri and m.member_did == ^member_did
        )
      )

  @doc "Members ordered by DID with `cursor:` (the last DID) and `limit:`."
  @spec list_members(String.t(), String.t(), keyword) :: [
          %{did: String.t(), member_rev: String.t()}
        ]
  def list_members(owner, uri, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    q =
      from(m in SpaceMember,
        where: m.did == ^owner and m.space == ^uri,
        order_by: [asc: m.member_did],
        limit: ^limit,
        select: %{did: m.member_did, member_rev: m.member_rev}
      )

    q = if c = opts[:cursor], do: where(q, [m], m.member_did > ^c), else: q
    Repo.all(q)
  end

  @spec add_member(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :member_already_exists}
  def add_member(owner, uri, member_did), do: apply_member_ops(owner, uri, [{:add, member_did}])

  @spec remove_member(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :member_not_found}
  def remove_member(owner, uri, member_did),
    do: apply_member_ops(owner, uri, [{:remove, member_did}])

  @doc "The member list's LtHash state and rev (nil before the first commit)."
  @spec member_state(String.t(), String.t()) ::
          %{set_hash: binary | nil, rev: String.t() | nil} | nil
  def member_state(owner, uri) do
    case Repo.get_by(SpaceMemberState, did: owner, space: uri) do
      nil -> nil
      %{set_hash: h, rev: rev} -> %{set_hash: h, rev: rev}
    end
  end

  # upstream SpaceMembers.formatCommit + applyMemberCommit, in one
  # transaction with the state row locked
  defp apply_member_ops(owner, uri, ops) do
    Repo.transaction(fn ->
      state =
        Repo.one(
          from(s in SpaceMemberState,
            where: s.did == ^owner and s.space == ^uri,
            lock: "FOR UPDATE"
          )
        ) || Repo.insert!(%SpaceMemberState{did: owner, space: uri})

      set_hash =
        Enum.reduce_while(ops, state.set_hash || LtHash.new(), fn
          {:add, did}, acc ->
            if member?(owner, uri, did),
              do: {:halt, {:error, :member_already_exists}},
              else: {:cont, LtHash.add(acc, did)}

          {:remove, did}, acc ->
            if member?(owner, uri, did),
              do: {:cont, LtHash.remove(acc, did)},
              else: {:halt, {:error, :member_not_found}}
        end)

      case set_hash do
        {:error, reason} ->
          Repo.rollback(reason)

        set_hash ->
          rev = Clock.next_tid()

          ops
          |> Enum.with_index()
          |> Enum.each(fn {{action, did}, idx} ->
            case action do
              :add ->
                Repo.insert!(%SpaceMember{
                  did: owner,
                  space: uri,
                  member_did: did,
                  member_rev: rev
                })

              :remove ->
                Repo.delete_all(
                  from(m in SpaceMember,
                    where: m.did == ^owner and m.space == ^uri and m.member_did == ^did
                  )
                )
            end

            Repo.insert!(%SpaceMemberOplog{
              did: owner,
              space: uri,
              rev: rev,
              idx: idx,
              action: Atom.to_string(action),
              member_did: did
            })
          end)

          state |> Ecto.Changeset.change(set_hash: set_hash, rev: rev) |> Repo.update!()
          rev
      end
    end)
  end

  # ------------------------------------------------- notify registrations

  @registration_ttl 24 * 3600

  @doc "`registerNotify`: upsert a subscriber (service identifier → endpoint); returns the expiry."
  @spec register_notify(String.t(), String.t(), String.t(), String.t()) :: DateTime.t()
  def register_notify(owner, uri, service, endpoint) do
    now = DateTime.utc_now()
    expires = DateTime.add(now, @registration_ttl, :second)

    Repo.insert!(
      %SpaceNotifyRegistration{
        did: owner,
        space: uri,
        service: service,
        endpoint: endpoint,
        expires_at: expires,
        created_at: now
      },
      on_conflict: [set: [endpoint: endpoint, expires_at: expires]],
      conflict_target: [:did, :space, :service]
    )

    expires
  end

  @doc "Live subscribers of a space: `[%{service, endpoint}]` (registrations + credential recipients)."
  @spec notify_targets(String.t(), String.t()) :: [%{service: String.t(), endpoint: String.t()}]
  def notify_targets(owner, uri) do
    now = DateTime.utc_now()

    regs =
      Repo.all(
        from(r in SpaceNotifyRegistration,
          where: r.did == ^owner and r.space == ^uri and r.expires_at > ^now,
          select: %{service: r.service, endpoint: r.endpoint}
        )
      )

    recipients =
      Repo.all(
        from(r in SpaceCredentialRecipient,
          where: r.did == ^owner and r.space == ^uri,
          select: %{service: r.service_did, endpoint: r.service_endpoint}
        )
      )

    Enum.uniq_by(regs ++ recipients, & &1.service)
  end

  # ------------------------------------------------------------- writers

  @doc "`notifyWrite` on the space host: remember the writer's latest rev (and hash when known)."
  @spec record_writer(String.t(), String.t(), String.t(), String.t(), binary | nil) :: :ok
  def record_writer(owner, uri, writer_did, rev, hash) do
    now = DateTime.utc_now()
    set = [rev: rev, updated_at: now] ++ if(hash, do: [hash: hash], else: [])

    Repo.insert!(
      %SpaceWriter{
        did: owner,
        space: uri,
        writer_did: writer_did,
        rev: rev,
        hash: hash,
        updated_at: now
      },
      on_conflict: [set: set],
      conflict_target: [:did, :space, :writer_did]
    )

    :ok
  end

  @doc "`listRepos`: the writer set, by DID, with `cursor:`/`limit:`."
  @spec list_writers(String.t(), String.t(), keyword) ::
          [%{did: String.t(), rev: String.t(), hash: binary | nil}]
  def list_writers(owner, uri, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    q =
      from(w in SpaceWriter,
        where: w.did == ^owner and w.space == ^uri,
        order_by: [asc: w.writer_did],
        limit: ^limit,
        select: %{did: w.writer_did, rev: w.rev, hash: w.hash}
      )

    q = if c = opts[:cursor], do: where(q, [w], w.writer_did > ^c), else: q
    Repo.all(q)
  end
end
