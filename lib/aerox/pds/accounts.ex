defmodule Aerox.PDS.Accounts do
  @moduledoc """
  Accounts and their lifecycle (DESIGN §18.3, upstream `account-manager`):
  lookup by handle/DID/email with the availability flags, status
  formatting, registration, handle updates, deactivate/activate/takedown/
  delete, passwords and app passwords (scrypt, §13.4), email tokens
  (§18.1), invite codes, and preferences. Everything here is one database;
  the cross-service steps of signup live in `Aerox.PDS.Signup`.
  """
  import Ecto.Query
  alias Aerox.ATProto.Syntax
  alias Aerox.Auth.Scrypt
  alias Aerox.PDS.{Repo, Sessions}

  alias Aerox.PDS.Schema.{
    Account,
    AccountPref,
    Actor,
    AppPassword,
    EmailToken,
    InviteCode,
    InviteCodeUse
  }

  @type account :: %{
          did: String.t(),
          handle: String.t() | nil,
          created_at: DateTime.t(),
          takedown_ref: String.t() | nil,
          deactivated_at: DateTime.t() | nil,
          delete_after: DateTime.t() | nil,
          email: String.t() | nil,
          email_confirmed_at: DateTime.t() | nil,
          invites_disabled: boolean
        }

  @email_token_ttl 15 * 60

  # ---------------------------------------------------------------- lookup

  defp base_query(flags) do
    q = from(a in Actor, left_join: acc in Account, on: acc.did == a.did, select: {a, acc})
    q = if flags[:include_taken_down], do: q, else: where(q, [a], is_nil(a.takedown_ref))
    if flags[:include_deactivated], do: q, else: where(q, [a], is_nil(a.deactivated_at))
  end

  defp to_account({%Actor{} = a, acc}) do
    %{
      did: a.did,
      handle: a.handle,
      created_at: a.created_at,
      takedown_ref: a.takedown_ref,
      deactivated_at: a.deactivated_at,
      delete_after: a.delete_after,
      email: acc && acc.email,
      email_confirmed_at: acc && acc.email_confirmed_at,
      invites_disabled: (acc && acc.invites_disabled) || false
    }
  end

  @doc "By handle or DID. Flags: `include_taken_down:`, `include_deactivated:`."
  @spec get_account(String.t(), keyword) :: account | nil
  def get_account(handle_or_did, flags \\ []) do
    q = base_query(flags)

    q =
      if String.starts_with?(handle_or_did, "did:"),
        do: where(q, [a], a.did == ^handle_or_did),
        else: where(q, [a], a.handle == ^handle_or_did)

    q |> Repo.one() |> then(&(&1 && to_account(&1)))
  end

  @spec get_accounts([String.t()], keyword) :: %{String.t() => account}
  def get_accounts(dids, flags \\ []) do
    base_query(flags)
    |> where([a], a.did in ^dids)
    |> Repo.all()
    |> Map.new(fn row ->
      acc = to_account(row)
      {acc.did, acc}
    end)
  end

  @spec get_by_email(String.t(), keyword) :: account | nil
  def get_by_email(email, flags \\ []) do
    base_query(flags)
    |> where([_, acc], acc.email == ^String.downcase(email))
    |> Repo.one()
    |> then(&(&1 && to_account(&1)))
  end

  @doc "The account's DID for a handle or DID, honouring the flags."
  @spec did_for_actor(String.t(), keyword) :: String.t() | nil
  def did_for_actor(handle_or_did, flags \\ []),
    do: get_account(handle_or_did, flags) |> then(&(&1 && &1.did))

  @doc "The signing keypair."
  @spec signing_keypair(String.t()) :: Aerox.ATProto.Crypto.Keypair.t() | nil
  def signing_keypair(did) do
    case Repo.one(from(a in Actor, where: a.did == ^did, select: a.signing_key)) do
      nil -> nil
      key -> Aerox.ATProto.Crypto.from_private(:k256, key)
    end
  end

  # ---------------------------------------------------------------- status

  @doc "Upstream `formatAccountStatus`: `{active?, status}`."
  @spec status(account | nil) :: {boolean, String.t()}
  def status(nil), do: {false, "deleted"}
  def status(%{takedown_ref: ref}) when not is_nil(ref), do: {false, "takendown"}
  def status(%{deactivated_at: at}) when not is_nil(at), do: {false, "deactivated"}
  def status(_), do: {true, "active"}

  @spec soft_deleted?(account) :: boolean
  def soft_deleted?(%{takedown_ref: ref}), do: not is_nil(ref)

  # -------------------------------------------------------------- register

  @doc """
  Inserts the actor (and the account row when email+password are given),
  records the invite use, and stores the initial refresh token. Runs inside
  the caller's transaction. `deactivated: true` registers the account
  deactivated with a 3-day `delete_after` (upstream), for the signup saga.
  """
  @spec register(map) ::
          {:ok, account} | {:error, :handle_taken | :email_taken | {:invite, String.t()}}
  def register(%{did: did, handle: handle, signing_key: key} = params) do
    now = DateTime.utc_now()
    deactivated = Map.get(params, :deactivated, false)

    with :ok <- ensure_invite_available(params[:invite_code]),
         {:ok, _} <-
           insert_actor(did, handle, key, now, deactivated, Map.get(params, :reap, true)),
         :ok <- maybe_insert_account(did, params[:email], params[:password]),
         :ok <- record_invite_use(params[:invite_code], did, now) do
      if params[:refresh_id] do
        Repo.insert_all(
          Aerox.PDS.Schema.RefreshToken,
          [%{id: params.refresh_id, did: did, expires_at: DateTime.add(now, 90 * 24 * 3600)}],
          on_conflict: :nothing
        )
      end

      {:ok, get_account(did, include_deactivated: true, include_taken_down: true)}
    end
  end

  defp insert_actor(did, handle, key, now, deactivated, reap) do
    actor = %Actor{
      did: did,
      handle: handle,
      signing_key: key,
      created_at: now,
      deactivated_at: if(deactivated, do: now),
      delete_after: if(deactivated and reap, do: DateTime.add(now, 3 * 24 * 3600))
    }

    case Repo.insert(actor, on_conflict: :nothing, conflict_target: :did) do
      {:ok, %{did: ^did}} ->
        if Repo.exists?(from(a in Actor, where: a.did == ^did)),
          do: {:ok, did},
          else: {:error, :handle_taken}

      _ ->
        {:error, :handle_taken}
    end
  rescue
    Ecto.ConstraintError -> {:error, :handle_taken}
  end

  defp maybe_insert_account(_did, nil, _), do: :ok
  defp maybe_insert_account(_did, _, nil), do: :ok

  defp maybe_insert_account(did, email, password) do
    case Repo.insert(
           %Account{
             did: did,
             email: String.downcase(email),
             password_scrypt: Scrypt.gen_salt_and_hash(password)
           },
           on_conflict: :nothing
         ) do
      {:ok, _} ->
        if Repo.exists?(from(a in Account, where: a.did == ^did)),
          do: :ok,
          else: {:error, :email_taken}

      _ ->
        {:error, :email_taken}
    end
  rescue
    Ecto.ConstraintError -> {:error, :email_taken}
  end

  # --------------------------------------------------------------- handles

  @spec update_handle(String.t(), String.t()) :: :ok | {:error, :not_found}
  def update_handle(did, handle) do
    case Repo.update_all(from(a in Actor, where: a.did == ^did), set: [handle: handle]) do
      {1, _} -> :ok
      _ -> {:error, :not_found}
    end
  end

  # ------------------------------------------------------------- lifecycle

  @spec deactivate(String.t(), DateTime.t() | nil) :: :ok | {:error, :not_found}
  def deactivate(did, delete_after \\ nil) do
    now = DateTime.utc_now()

    case Repo.update_all(from(a in Actor, where: a.did == ^did and is_nil(a.deactivated_at)),
           set: [deactivated_at: now, delete_after: delete_after]
         ) do
      {1, _} ->
        :ok

      _ ->
        if Repo.exists?(from(a in Actor, where: a.did == ^did)),
          do: :ok,
          else: {:error, :not_found}
    end
  end

  @spec activate(String.t()) :: :ok | {:error, :not_found}
  def activate(did) do
    case Repo.update_all(from(a in Actor, where: a.did == ^did and is_nil(a.takedown_ref)),
           set: [deactivated_at: nil, delete_after: nil]
         ) do
      {1, _} -> :ok
      _ -> {:error, :not_found}
    end
  end

  @doc "Sets or clears the takedown; sessions are revoked on takedown (upstream `takedownAccount`)."
  @spec set_takedown(String.t(), String.t() | nil) :: :ok
  def set_takedown(did, ref) do
    Repo.transaction(fn ->
      Repo.update_all(from(a in Actor, where: a.did == ^did), set: [takedown_ref: ref])
      if ref, do: Sessions.revoke_all(did)
    end)

    :ok
  end

  @doc "Deletes every row of an account (cascades from actor); blob objects are the caller's job (DESIGN §4.4)."
  @spec delete_account(String.t()) :: :ok
  def delete_account(did) do
    Repo.delete_all(from(a in Actor, where: a.did == ^did))
    :ok
  end

  # -------------------------------------------------------------- passwords

  @doc "Upstream `login`: by email (contains @) or at-identifier; account password first, then app passwords."
  @spec login(String.t(), String.t()) ::
          {:ok, account, map | nil} | {:error, :invalid_login | :password_too_long}
  def login(identifier, password) do
    identifier = String.downcase(identifier)
    flags = [include_deactivated: true, include_taken_down: true]

    account =
      cond do
        String.contains?(identifier, "@") -> get_by_email(identifier, flags)
        Syntax.valid_at_identifier?(identifier) -> get_account(identifier, flags)
        true -> nil
      end

    cond do
      byte_size(password) > Scrypt.old_password_max_length() ->
        {:error, :password_too_long}

      is_nil(account) ->
        {:error, :invalid_login}

      verify_account_password(account.did, password) ->
        {:ok, account, nil}

      soft_deleted?(account) ->
        {:error, :invalid_login}

      true ->
        case verify_app_password(account.did, password) do
          nil -> {:error, :invalid_login}
          app -> {:ok, account, app}
        end
    end
  end

  @spec verify_account_password(String.t(), String.t()) :: boolean
  def verify_account_password(did, password) do
    case Repo.one(from(a in Account, where: a.did == ^did, select: a.password_scrypt)) do
      nil -> false
      stored -> Scrypt.verify(password, stored)
    end
  end

  @spec verify_app_password(String.t(), String.t()) ::
          %{name: String.t(), privileged: boolean} | nil
  def verify_app_password(did, password) do
    hashed = Scrypt.hash_app_password(did, password)

    case Repo.one(from(p in AppPassword, where: p.did == ^did and p.password_scrypt == ^hashed)) do
      nil -> nil
      p -> %{name: p.name, privileged: p.privileged}
    end
  end

  @spec update_password(String.t(), String.t()) :: :ok
  def update_password(did, password) do
    Repo.update_all(from(a in Account, where: a.did == ^did),
      set: [password_scrypt: Scrypt.gen_salt_and_hash(password)]
    )

    Sessions.revoke_all(did)
    :ok
  end

  @doc "Accounts whose email contains `fragment` (case-insensitive), ordered by DID; `{accounts, next_cursor}`."
  @spec search_by_email(String.t() | nil, pos_integer, String.t() | nil) ::
          {[account], String.t() | nil}
  def search_by_email(fragment, limit, cursor) do
    q = base_query(include_deactivated: true, include_taken_down: true)

    q =
      case fragment do
        f when is_binary(f) and f != "" ->
          like = "%" <> String.replace(String.downcase(f), ["\\", "%", "_"], &("\\" <> &1)) <> "%"
          where(q, [_, acc], like(acc.email, ^like))

        _ ->
          q
      end

    q = if cursor, do: where(q, [a], a.did > ^cursor), else: q

    rows =
      q |> order_by([a], asc: a.did) |> limit(^limit) |> Repo.all() |> Enum.map(&to_account/1)

    next = if length(rows) == limit, do: List.last(rows).did
    {rows, next}
  end

  @doc "Replaces the account's repo signing key (the private key is stored as for a new account)."
  def update_signing_key(did, %Aerox.ATProto.Crypto.Keypair{private: private}) do
    Repo.update_all(from(a in Actor, where: a.did == ^did), set: [signing_key: private])
    :ok
  end

  @doc """
  Upstream `revokeAccountCredentials`: refresh tokens, OAuth tokens and app
  passwords are deleted and the password is replaced by an unusable random
  one, so only a password reset lets the owner back in.
  """
  def revoke_credentials(did) do
    Repo.transaction(fn ->
      Sessions.revoke_all(did)
      Aerox.PDS.OAuth.Tokens.revoke_all(did)
      Repo.delete_all(from(p in AppPassword, where: p.did == ^did))

      Repo.update_all(from(a in Account, where: a.did == ^did),
        set: [
          password_scrypt: Scrypt.gen_salt_and_hash(Base.encode64(:crypto.strong_rand_bytes(32)))
        ]
      )
    end)

    :ok
  end

  @doc "Upstream `createAppPassword`: a random `xxxx-xxxx-xxxx-xxxx` password, stored hashed."
  @spec create_app_password(String.t(), String.t(), boolean) ::
          {:ok,
           %{
             name: String.t(),
             password: String.t(),
             created_at: DateTime.t(),
             privileged: boolean
           }}
          | {:error, :name_taken}
  def create_app_password(did, name, privileged \\ false) do
    password =
      :crypto.strong_rand_bytes(16)
      |> Base.encode32(case: :lower, padding: false)
      |> String.slice(0, 16)
      |> then(&Regex.replace(~r/(.{4})(?=.)/, &1, "\\1-"))

    now = DateTime.utc_now()

    case Repo.insert(%AppPassword{
           did: did,
           name: name,
           password_scrypt: Scrypt.hash_app_password(did, password),
           created_at: now,
           privileged: privileged
         }) do
      {:ok, _} ->
        {:ok, %{name: name, password: password, created_at: now, privileged: privileged}}

      {:error, _} ->
        {:error, :name_taken}
    end
  rescue
    Ecto.ConstraintError -> {:error, :name_taken}
  end

  @spec list_app_passwords(String.t()) :: [
          %{name: String.t(), created_at: DateTime.t(), privileged: boolean}
        ]
  def list_app_passwords(did) do
    from(p in AppPassword,
      where: p.did == ^did,
      order_by: [asc: p.created_at],
      select: %{name: p.name, created_at: p.created_at, privileged: p.privileged}
    )
    |> Repo.all()
  end

  @spec revoke_app_password(String.t(), String.t()) :: :ok
  def revoke_app_password(did, name) do
    Repo.transaction(fn ->
      Repo.delete_all(from(p in AppPassword, where: p.did == ^did and p.name == ^name))
      Sessions.revoke_app_password_tokens(did, name)
    end)

    :ok
  end

  # ----------------------------------------------------------- email tokens

  @purposes ~w(confirm_email update_email reset_password delete_account plc_operation)
  def email_token_purposes, do: @purposes

  @doc "Creates (replacing any outstanding) token for `(did, purpose)`; returns the token."
  @spec create_email_token(String.t(), String.t()) :: String.t()
  def create_email_token(did, purpose) when purpose in @purposes do
    token =
      :crypto.strong_rand_bytes(5)
      |> Base.encode32(padding: false)
      |> then(&(binary_part(&1, 0, 5) <> "-" <> binary_part(&1, 5, 3)))

    token =
      String.upcase(token)
      |> then(fn t ->
        String.slice(t, 0, 5) <>
          "-" <>
          (:crypto.strong_rand_bytes(4) |> Base.encode32(padding: false) |> String.slice(0, 5))
      end)

    Repo.insert_all(
      EmailToken,
      [%{purpose: purpose, did: did, token: token, requested_at: DateTime.utc_now()}],
      on_conflict: {:replace, [:token, :requested_at]},
      conflict_target: [:purpose, :did]
    )

    token
  end

  @doc "Valid, unexpired token for `(did, purpose)`? Case-insensitive, as upstream."
  @spec assert_email_token(String.t(), String.t(), String.t()) ::
          :ok | {:error, :invalid_token | :expired_token}
  def assert_email_token(did, purpose, token) do
    case Repo.one(from(t in EmailToken, where: t.purpose == ^purpose and t.did == ^did)) do
      nil ->
        {:error, :invalid_token}

      %{token: stored} = row ->
        cond do
          String.upcase(stored) != String.upcase(token) ->
            {:error, :invalid_token}

          DateTime.diff(DateTime.utc_now(), row.requested_at) > @email_token_ttl ->
            {:error, :expired_token}

          true ->
            :ok
        end
    end
  end

  @doc "Validates and consumes the token."
  @spec assert_email_token_and_cleanup(String.t(), String.t(), String.t()) ::
          :ok | {:error, :invalid_token | :expired_token}
  def assert_email_token_and_cleanup(did, purpose, token) do
    with :ok <- assert_email_token(did, purpose, token) do
      Repo.delete_all(from(t in EmailToken, where: t.purpose == ^purpose and t.did == ^did))
      :ok
    end
  end

  @doc "The DID a `reset_password` token belongs to (password reset carries no session)."
  @spec did_for_email_token(String.t(), String.t()) :: String.t() | nil
  def did_for_email_token(purpose, token) do
    up = String.upcase(token)

    Repo.one(
      from(t in EmailToken,
        where: t.purpose == ^purpose and fragment("upper(?)", t.token) == ^up,
        select: t.did
      )
    )
  end

  @spec confirm_email(String.t(), String.t(), String.t()) :: :ok | {:error, term}
  def confirm_email(did, email, token) do
    with account when not is_nil(account) <- get_account(did, include_deactivated: true),
         :ok <-
           if(account.email == String.downcase(email), do: :ok, else: {:error, :invalid_email}),
         :ok <- assert_email_token_and_cleanup(did, "confirm_email", token) do
      Repo.update_all(from(a in Account, where: a.did == ^did),
        set: [email_confirmed_at: DateTime.utc_now()]
      )

      :ok
    else
      nil -> {:error, :not_found}
      e -> e
    end
  end

  @spec update_email(String.t(), String.t()) :: :ok | {:error, :email_taken}
  def update_email(did, email) do
    email = String.downcase(email)

    if Repo.exists?(from(a in Account, where: a.email == ^email and a.did != ^did)) do
      {:error, :email_taken}
    else
      Repo.update_all(from(a in Account, where: a.did == ^did),
        set: [email: email, email_confirmed_at: nil]
      )

      :ok
    end
  end

  # ------------------------------------------------------------ invite codes

  @spec ensure_invite_available(String.t() | nil) :: :ok | {:error, {:invite, String.t()}}
  def ensure_invite_available(nil), do: :ok

  def ensure_invite_available(code) do
    case Repo.one(from(i in InviteCode, where: i.code == ^code)) do
      nil ->
        {:error, {:invite, "Provided invite code not available"}}

      %{disabled: true} ->
        {:error, {:invite, "Provided invite code not available"}}

      invite ->
        uses = Repo.aggregate(from(u in InviteCodeUse, where: u.code == ^code), :count)

        if uses >= invite.available_uses,
          do: {:error, {:invite, "Provided invite code not available"}},
          else: :ok
    end
  end

  defp record_invite_use(nil, _did, _now), do: :ok

  defp record_invite_use(code, did, now) do
    Repo.insert!(%InviteCodeUse{code: code, used_by: did, used_at: now})
    :ok
  end

  @spec create_invite_codes(String.t(), pos_integer, pos_integer) :: [String.t()]
  def create_invite_codes(for_account, count, uses \\ 1) do
    host = Aerox.PDS.Config.hostname() |> String.replace(".", "-")
    now = DateTime.utc_now()

    codes =
      for _ <- 1..count do
        rand = :crypto.strong_rand_bytes(5) |> Base.encode32(case: :lower, padding: false)
        "#{host}-#{String.slice(rand, 0, 5)}-#{String.slice(rand, 5, 5)}"
      end

    Repo.insert_all(
      InviteCode,
      Enum.map(
        codes,
        &%{
          code: &1,
          available_uses: uses,
          disabled: false,
          for_account: for_account,
          created_by: for_account,
          created_at: now
        }
      )
    )

    codes
  end

  @spec account_invite_codes(String.t()) :: [map]
  @doc """
  Every invite code, newest first (`sort: "recent"`, keyset `createdAt::code`)
  or most used first (`"usage"`, keyset `uses::code`), as upstream
  (the time is in microseconds, the precision it is stored at)
  `admin.getInviteCodes`. Returns the codes (in `account_invite_codes/1`'s
  shape) and the next cursor.
  """
  @spec list_invite_codes(String.t(), pos_integer, String.t() | nil) ::
          {:ok, [map], String.t() | nil} | {:error, :malformed_cursor | :unknown_sort}
  def list_invite_codes(sort, limit, cursor) do
    uses_q = from(u in InviteCodeUse, group_by: u.code, select: %{code: u.code, n: count()})

    base =
      from(i in InviteCode,
        left_join: u in subquery(uses_q),
        on: u.code == i.code,
        select: %{row: i, uses: coalesce(u.n, 0)}
      )

    with {:ok, query} <- invite_keyset(base, sort, cursor) do
      rows = query |> limit(^limit) |> Repo.all()

      next =
        case List.last(rows) do
          nil -> nil
          %{row: i, uses: n} when sort == "usage" -> "#{n}::#{i.code}"
          %{row: i} -> "#{DateTime.to_unix(i.created_at, :microsecond)}::#{i.code}"
        end

      uses =
        Repo.all(from(u in InviteCodeUse, where: u.code in ^Enum.map(rows, & &1.row.code)))
        |> Enum.group_by(& &1.code)

      codes =
        Enum.map(rows, fn %{row: c} ->
          %{
            code: c.code,
            available: c.available_uses,
            disabled: c.disabled,
            for_account: c.for_account,
            created_by: c.created_by,
            created_at: c.created_at,
            uses: Enum.map(uses[c.code] || [], &%{used_by: &1.used_by, used_at: &1.used_at})
          }
        end)

      {:ok, codes, next}
    end
  end

  defp invite_keyset(base, sort, cursor) do
    with {:ok, parsed} <- parse_invite_cursor(cursor) do
      case {sort, parsed} do
        {"recent", nil} ->
          {:ok, order_by(base, [i], desc: i.created_at, desc: i.code)}

        {"recent", {primary, code}} ->
          with {us, ""} <- Integer.parse(primary),
               {:ok, at} <- DateTime.from_unix(us, :microsecond) do
            {:ok,
             base
             |> where([i], i.created_at < ^at or (i.created_at == ^at and i.code < ^code))
             |> order_by([i], desc: i.created_at, desc: i.code)}
          else
            _ -> {:error, :malformed_cursor}
          end

        {"usage", nil} ->
          {:ok, order_by(base, [i, u], desc: coalesce(u.n, 0), desc: i.code)}

        {"usage", {primary, code}} ->
          case Integer.parse(primary) do
            {n, ""} ->
              {:ok,
               base
               |> where(
                 [i, u],
                 coalesce(u.n, 0) < ^n or (coalesce(u.n, 0) == ^n and i.code < ^code)
               )
               |> order_by([i, u], desc: coalesce(u.n, 0), desc: i.code)}

            _ ->
              {:error, :malformed_cursor}
          end

        _ ->
          {:error, :unknown_sort}
      end
    end
  end

  defp parse_invite_cursor(nil), do: {:ok, nil}

  defp parse_invite_cursor(cursor) do
    case String.split(cursor, "::") do
      [primary, code] when primary != "" and code != "" -> {:ok, {primary, code}}
      _ -> {:error, :malformed_cursor}
    end
  end

  def account_invite_codes(did) do
    codes =
      Repo.all(from(i in InviteCode, where: i.for_account == ^did, order_by: [asc: i.created_at]))

    uses =
      Repo.all(from(u in InviteCodeUse, where: u.code in ^Enum.map(codes, & &1.code)))
      |> Enum.group_by(& &1.code)

    Enum.map(codes, fn c ->
      %{
        code: c.code,
        available: c.available_uses,
        disabled: c.disabled,
        for_account: c.for_account,
        created_by: c.created_by,
        created_at: c.created_at,
        uses: Enum.map(uses[c.code] || [], &%{used_by: &1.used_by, used_at: &1.used_at})
      }
    end)
  end

  # ------------------------------------------------------------ preferences

  @full_access_only ~w(app.bsky.actor.defs#personalDetailsPref)
  @read_only ~w(app.bsky.actor.defs#declaredAgePref)

  @doc "Preferences in a namespace; `full_access?` false hides the full-access-only ones (upstream `prefAllowed`)."
  @spec get_preferences(String.t(), String.t(), boolean) :: [map]
  def get_preferences(did, namespace, full_access? \\ true) do
    from(p in AccountPref, where: p.did == ^did, order_by: [asc: p.id], select: p.value)
    |> Repo.all()
    |> Enum.filter(&namespace_match?(namespace, &1["$type"]))
    |> then(&(&1 ++ declared_age(&1)))
    |> Enum.filter(&(full_access? or &1["$type"] not in @full_access_only))
  end

  defp declared_age(prefs) do
    case Enum.find(prefs, &(&1["$type"] == "app.bsky.actor.defs#personalDetailsPref")) do
      %{"birthDate" => bd} when is_binary(bd) ->
        case Date.from_iso8601(String.slice(bd, 0, 10)) do
          {:ok, date} ->
            today = Date.utc_today()

            age =
              today.year - date.year -
                if({today.month, today.day} < {date.month, date.day}, do: 1, else: 0)

            [
              %{
                "$type" => "app.bsky.actor.defs#declaredAgePref",
                "isOverAge13" => age >= 13,
                "isOverAge16" => age >= 16,
                "isOverAge18" => age >= 18
              }
            ]

          _ ->
            []
        end

      _ ->
        []
    end
  end

  @spec put_preferences(String.t(), [map], String.t(), boolean) :: :ok | {:error, String.t()}
  def put_preferences(did, values, namespace, full_access? \\ true) do
    cond do
      not Enum.all?(values, &is_binary(&1["$type"])) ->
        {:error, "Preference is missing a $type"}

      not Enum.all?(values, &namespace_match?(namespace, &1["$type"])) ->
        {:error, "Some preferences are not in the #{namespace} namespace"}

      not full_access? and Enum.any?(values, &(&1["$type"] in @full_access_only)) ->
        {:error,
         "Do not have authorization to set preferences: #{values |> Enum.filter(&(&1["$type"] in @full_access_only)) |> Enum.map_join(", ", & &1["$type"])}"}

      true ->
        Repo.transaction(fn ->
          existing =
            Repo.all(from(p in AccountPref, where: p.did == ^did, select: {p.id, p.name}))

          ids =
            for {id, name} <- existing,
                namespace_match?(namespace, name),
                full_access? or name not in @full_access_only,
                do: id

          if ids != [], do: Repo.delete_all(from(p in AccountPref, where: p.id in ^ids))

          rows =
            for v <- values,
                v["$type"] not in @read_only,
                do: %{did: did, name: v["$type"], value: v}

          if rows != [], do: Repo.insert_all(AccountPref, rows)
        end)

        :ok
    end
  end

  defp namespace_match?(ns, name) when is_binary(name),
    do: name == ns or String.starts_with?(name, ns <> ".")

  defp namespace_match?(_, _), do: false
end
