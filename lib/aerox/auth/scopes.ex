defmodule Aerox.Auth.Scopes do
  @moduledoc """
  atproto OAuth scope grammar and evaluation (DESIGN §11.2, §12; upstream
  `@atproto/oauth-scopes`). A scope string is `<prefix>[:<positional>][?<params>]`;
  the granular prefixes are `repo`, `rpc`, `blob`, `account`, `identity`,
  `space` (permissioned data), and `include` (a permission-set lexicon whose
  `permissions` expand into `repo`/`rpc` scopes). `atproto` and the
  transitional `transition:{generic,email,chat.bsky}` are plain tokens.

  Pure: `parse/1` gives the permission a scope string denotes, `matches?/3`
  answers "may this granted scope string do X on Y", and `expand/2`
  resolves `include:` scopes against a lexicon registry.
  """
  alias Aerox.ATProto.Syntax

  @repo_actions ~w(create update delete)
  @account_attributes ~w(email repo status)
  @account_actions ~w(read manage)
  @identity_attributes ~w(handle *)
  # The published spaces alpha (`@atproto/oauth-scopes@0.0.0-spaces-alpha-20260818163953`,
  # `space-permission.ts`), which is what `bulletin` and its permission set speak:
  # `authority` (default `self`, resolved to the user at issuance), separate
  # `manage` ops, and `read_self` as the narrowest action.
  @space_actions ~w(read_self read create update delete)
  @space_default_actions ~w(read create update delete)
  @space_manage_ops ~w(create update delete)

  @type permission ::
          {:repo, %{collection: [String.t()], action: [String.t()]}}
          | {:rpc, %{lxm: [String.t()], aud: String.t()}}
          | {:blob, %{accept: [String.t()]}}
          | {:account, %{attr: String.t(), action: [String.t()]}}
          | {:identity, %{attr: String.t()}}
          | {:space,
             %{
               type: String.t(),
               authority: String.t(),
               skey: String.t(),
               collection: [String.t()],
               action: [String.t()],
               manage: [String.t()]
             }}
          | {:include, %{nsid: String.t(), aud: String.t() | nil}}
          | {:atproto, nil}
          | {:transition, String.t()}

  # ------------------------------------------------------------- syntax

  @doc "Splits a scope string into `{prefix, positional | nil, params}` (params as a list of `{key, value}`)."
  @spec syntax(String.t()) :: {String.t(), String.t() | nil, [{String.t(), String.t()}]}
  def syntax(scope) when is_binary(scope) do
    param_idx = index_of(scope, "?")
    colon_idx = index_of(scope, ":")

    prefix_end =
      case {param_idx, colon_idx} do
        {nil, nil} -> nil
        {nil, c} -> c
        {p, nil} -> p
        {p, c} -> min(p, c)
      end

    if is_nil(prefix_end) do
      {scope, nil, []}
    else
      prefix = binary_part(scope, 0, prefix_end)

      positional =
        cond do
          is_nil(colon_idx) ->
            nil

          is_nil(param_idx) ->
            scope |> binary_part(colon_idx + 1, byte_size(scope) - colon_idx - 1) |> URI.decode()

          colon_idx < param_idx ->
            scope |> binary_part(colon_idx + 1, param_idx - colon_idx - 1) |> URI.decode()

          true ->
            nil
        end

      params =
        if param_idx && param_idx < byte_size(scope) - 1,
          do:
            scope
            |> binary_part(param_idx + 1, byte_size(scope) - param_idx - 1)
            |> URI.query_decoder()
            |> Enum.to_list(),
          else: []

      {prefix, positional, params}
    end
  end

  defp index_of(s, ch) do
    case :binary.match(s, ch) do
      {i, _} -> i
      :nomatch -> nil
    end
  end

  # Generic parameter parsing (upstream `Parser`): a schema of
  # `{key, multiple?, required?, default, validator, normalizer}`, with one
  # key allowed as the positional value.
  defp parse_params({_prefix, positional, params}, schema, positional_key) do
    known = Enum.map(schema, &elem(&1, 0))

    if Enum.any?(params, fn {k, _} -> k not in known end) do
      nil
    else
      Enum.reduce_while(schema, {:ok, %{}}, fn {key, multiple?, required?, default, validate,
                                                normalize},
                                               {:ok, acc} ->
        values = for {k, v} <- params, k == key, do: v
        atom = String.to_atom(key)

        cond do
          values != [] and key == positional_key and positional != nil ->
            {:halt, nil}

          values != [] and multiple? ->
            if Enum.all?(values, validate),
              do: {:cont, {:ok, Map.put(acc, atom, normalize.(values))}},
              else: {:halt, nil}

          values != [] ->
            case values do
              [v] ->
                if validate.(v),
                  do: {:cont, {:ok, Map.put(acc, atom, normalize.(v))}},
                  else: {:halt, nil}

              _ ->
                {:halt, nil}
            end

          key == positional_key and positional != nil ->
            if validate.(positional),
              do:
                {:cont,
                 {:ok,
                  Map.put(
                    acc,
                    atom,
                    normalize.(if(multiple?, do: [positional], else: positional))
                  )}},
              else: {:halt, nil}

          required? ->
            {:halt, nil}

          true ->
            {:cont, {:ok, Map.put(acc, atom, default)}}
        end
      end)
      |> case do
        {:ok, map} -> map
        nil -> nil
      end
    end
  end

  defp id(v), do: v
  defp nsid?(v), do: is_binary(v) and Syntax.valid_nsid?(v)
  defp star_or_nsid?(v), do: v == "*" or nsid?(v)
  defp one_of(list), do: fn v -> v in list end

  defp sort_unique_or_star(values) do
    if length(values) > 1 do
      if "*" in values, do: ["*"], else: values |> Enum.uniq() |> Enum.sort()
    else
      values
    end
  end

  defp filter_in_order(all), do: fn values -> Enum.filter(all, &(&1 in values)) end

  defp did_ref?(v),
    do:
      is_binary(v) and Syntax.valid_did?(String.split(v, "#") |> hd()) and
        (String.contains?(v, "#") or true)

  defp did?(v), do: is_binary(v) and Syntax.valid_did?(v)

  # -------------------------------------------------------------- parse

  @doc "The permission a scope string denotes, or nil when it is not a valid scope."
  @spec parse(String.t()) :: permission | nil
  def parse("atproto"), do: {:atproto, nil}

  def parse("transition:" <> rest = _s) when rest in ["generic", "email", "chat.bsky"],
    do: {:transition, rest}

  def parse(scope) when is_binary(scope) do
    {prefix, _, _} = syn = syntax(scope)

    case prefix do
      "repo" -> parse_repo(syn)
      "rpc" -> parse_rpc(syn)
      "blob" -> parse_blob(syn)
      "account" -> parse_account(syn)
      "identity" -> parse_identity(syn)
      "space" -> parse_space(syn)
      "include" -> parse_include(syn)
      _ -> nil
    end
  end

  defp parse_repo(syn) do
    schema = [
      {"collection", true, true, nil, &star_or_nsid?/1, &sort_unique_or_star/1},
      {"action", true, false, @repo_actions, one_of(@repo_actions),
       filter_in_order(@repo_actions)}
    ]

    case parse_params(syn, schema, "collection") do
      nil -> nil
      %{collection: c, action: a} -> {:repo, %{collection: c, action: a}}
    end
  end

  defp parse_rpc(syn) do
    schema = [
      {"lxm", true, true, nil, &star_or_nsid?/1, &sort_unique_or_star/1},
      {"aud", false, true, nil, fn v -> v == "*" or did_ref?(v) end, &id/1}
    ]

    case parse_params(syn, schema, "lxm") do
      %{lxm: lxm, aud: "*"} = _ when is_list(lxm) ->
        if("*" in lxm, do: nil, else: {:rpc, %{lxm: lxm, aud: "*"}})

      %{lxm: lxm, aud: aud} ->
        {:rpc, %{lxm: lxm, aud: aud}}

      nil ->
        nil
    end
  end

  defp parse_blob(syn) do
    accept? = fn v ->
      (is_binary(v) and Regex.match?(~r|^[\w.+-]+/[\w.+*-]+$|, v)) or v == "*/*"
    end

    schema = [
      {"accept", true, true, nil, accept?,
       fn v -> if("*/*" in v, do: ["*/*"], else: v |> Enum.uniq() |> Enum.sort()) end}
    ]

    case parse_params(syn, schema, "accept") do
      nil -> nil
      %{accept: a} -> {:blob, %{accept: a}}
    end
  end

  defp parse_account(syn) do
    schema = [
      {"attr", false, true, nil, one_of(@account_attributes), &id/1},
      {"action", true, false, ["read"], one_of(@account_actions),
       filter_in_order(@account_actions)}
    ]

    case parse_params(syn, schema, "attr") do
      nil -> nil
      %{attr: attr, action: action} -> {:account, %{attr: attr, action: action}}
    end
  end

  defp parse_identity(syn) do
    schema = [{"attr", false, true, nil, one_of(@identity_attributes), &id/1}]

    case parse_params(syn, schema, "attr") do
      nil -> nil
      %{attr: attr} -> {:identity, %{attr: attr}}
    end
  end

  defp parse_space(syn) do
    schema = [
      {"type", false, true, nil, &star_or_nsid?/1, &id/1},
      {"authority", false, false, "self", fn v -> v in ["*", "self"] or did?(v) end, &id/1},
      {"skey", false, false, "*", fn v -> v == "*" or Syntax.valid_record_key?(v) end, &id/1},
      {"collection", true, false, [], &star_or_nsid?/1, &sort_unique_or_star/1},
      {"action", true, false, @space_default_actions, one_of(@space_actions),
       filter_in_order(@space_actions)},
      {"manage", true, false, [], one_of(@space_manage_ops), filter_in_order(@space_manage_ops)}
    ]

    case parse_params(syn, schema, "type") do
      nil -> nil
      %{} = p -> {:space, p}
    end
  end

  defp parse_include(syn) do
    schema = [
      {"nsid", false, true, nil, &nsid?/1, &id/1},
      {"aud", false, false, nil, &did_ref?/1, &id/1}
    ]

    case parse_params(syn, schema, "nsid") do
      nil -> nil
      %{nsid: nsid, aud: aud} -> {:include, %{nsid: nsid, aud: aud}}
    end
  end

  # ------------------------------------------------------------- format

  @doc "The canonical string of a permission (upstream `toString`)."
  @spec format(permission) :: String.t()
  def format({:atproto, _}), do: "atproto"
  def format({:transition, t}), do: "transition:" <> t

  def format({:repo, %{collection: c, action: a}}),
    do: build("repo", c, [{"action", a, @repo_actions}])

  def format({:rpc, %{lxm: lxm, aud: aud}}), do: build("rpc", lxm, [{"aud", aud, nil}])
  def format({:blob, %{accept: a}}), do: build("blob", a, [])

  def format({:account, %{attr: attr, action: a}}),
    do: build("account", attr, [{"action", a, ["read"]}])

  def format({:identity, %{attr: attr}}), do: build("identity", attr, [])

  def format({:space, %{type: t, authority: auth, skey: skey, collection: c, action: a} = p}),
    do:
      build("space", t, [
        {"authority", auth, "self"},
        {"skey", skey, "*"},
        {"collection", c, []},
        {"action", a, @space_default_actions},
        {"manage", Map.get(p, :manage, []), []}
      ])

  def format({:include, %{nsid: nsid, aud: aud}}), do: build("include", nsid, [{"aud", aud, nil}])

  defp build(prefix, positional, params) do
    {positional, extra} =
      case positional do
        [one] -> {one, []}
        list when is_list(list) -> {nil, [{"__positional", list, nil}]}
        v -> {v, []}
      end

    positional_key =
      case prefix do
        "repo" -> "collection"
        "rpc" -> "lxm"
        "blob" -> "accept"
        "account" -> "attr"
        "identity" -> "attr"
        "space" -> "type"
        "include" -> "nsid"
      end

    query =
      (Enum.map(extra, fn {_, list, _} -> {positional_key, list} end) ++
         for({k, v, default} <- params, v != nil, v != default, do: {k, v}))
      |> Enum.flat_map(fn
        {k, list} when is_list(list) -> Enum.map(list, &{k, &1})
        {k, v} -> [{k, v}]
      end)

    base = if positional, do: "#{prefix}:#{encode(positional)}", else: prefix

    if query == [],
      do: base,
      else: base <> "?" <> Enum.map_join(query, "&", fn {k, v} -> "#{k}=#{encode(v)}" end)
  end

  # upstream normalizeURIComponent: these stay literal inside a scope
  # (`*` too: URLSearchParams never encodes it)
  @literal ["%3A", "%2F", "%2B", "%2C", "%40", "%25", "%2A"]
  defp encode(v), do: v |> URI.encode_www_form() |> String.replace(@literal, &unescape/1)

  defp unescape("%2A"), do: "*"
  defp unescape("%3A"), do: ":"
  defp unescape("%2F"), do: "/"
  defp unescape("%2B"), do: "+"
  defp unescape("%2C"), do: ","
  defp unescape("%40"), do: "@"
  defp unescape("%25"), do: "%"

  # ------------------------------------------------------------ matching

  @doc """
  Does a single granted scope allow the resource access?
  `resource` is `:repo | :rpc | :blob | :account | :identity | :space`.
  """
  @spec matches?(String.t() | permission, atom, map) :: boolean
  def matches?(scope, resource, target) when is_binary(scope),
    do: matches?(parse(scope), resource, target)

  def matches?({:repo, %{collection: c, action: a}}, :repo, %{
        collection: collection,
        action: action
      }),
      do: action in a and ("*" in c or collection in c)

  def matches?({:rpc, %{lxm: lxm, aud: aud}}, :rpc, %{lxm: l, aud: a}),
    do: (aud == "*" or aud == a) and ("*" in lxm or l in lxm)

  def matches?({:blob, %{accept: accept}}, :blob, %{mime: mime}),
    do: Enum.any?(accept, &mime_matches?(&1, mime))

  def matches?({:account, %{attr: attr, action: a}}, :account, %{attr: at, action: action}),
    do: attr == at and ("manage" in a or action in a)

  def matches?({:identity, %{attr: attr}}, :identity, %{attr: at}), do: attr == "*" or attr == at

  # Alpha `SpacePermission.matches`: an unresolved `self` authority matches
  # nothing (targets always carry a concrete DID); a target with `manage:`
  # is a space-management op; reads are collection-independent and `read`
  # implies `read_self`.
  def matches?({:space, p}, :space, %{type: t, authority: d, skey: s} = target) do
    cond do
      p.type != "*" and p.type != t -> false
      p.authority != "*" and p.authority != d -> false
      p.skey != "*" and p.skey != s -> false
      Map.has_key?(target, :manage) -> target.manage in Map.get(p, :manage, [])
      target[:action] == "read" -> "read" in p.action
      target[:action] == "read_self" -> "read" in p.action or "read_self" in p.action
      target[:action] not in p.action -> false
      true -> "*" in p.collection or target[:collection] in p.collection
    end
  end

  def matches?(_, _, _), do: false

  defp mime_matches?("*/*", _), do: true

  defp mime_matches?(accept, mime) do
    case String.split(accept, "/") do
      [base, "*"] -> String.starts_with?(mime, base <> "/")
      _ -> accept == mime
    end
  end

  @doc "The scope that would be needed for a target (upstream `scopeNeededFor`)."
  def needed_for(:repo, %{collection: c, action: a}),
    do: format({:repo, %{collection: [c], action: [a]}})

  def needed_for(:rpc, %{lxm: l, aud: a}), do: format({:rpc, %{lxm: [l], aud: a}})
  def needed_for(:blob, %{mime: m}), do: format({:blob, %{accept: [m]}})

  def needed_for(:account, %{attr: at, action: a}),
    do: format({:account, %{attr: at, action: [a]}})

  def needed_for(:identity, %{attr: at}), do: format({:identity, %{attr: at}})

  def needed_for(:space, %{type: t, authority: d, skey: s, manage: m}),
    do:
      format(
        {:space,
         %{type: t, authority: d, skey: s, collection: [], action: ["read_self"], manage: [m]}}
      )

  def needed_for(:space, %{type: t, authority: d, skey: s, action: a} = target),
    do:
      format(
        {:space,
         %{
           type: t,
           authority: d,
           skey: s,
           collection:
             if(a in ["read", "read_self"], do: [], else: List.wrap(target[:collection])),
           action: [a],
           manage: []
         }}
      )

  @doc """
  Issuance-time resolution of `space:` permissions (alpha `withResolvedAuthority`
  / `withDefaultCollections`): `authority=self` becomes the user's DID and a
  grant without `collection` takes the space type's declared collections.
  """
  @spec resolve_space([permission], String.t(), (String.t() -> [String.t()])) :: [permission]
  def resolve_space(perms, user_did, collections \\ &default_space_collections/1) do
    Enum.map(perms, fn
      {:space, %{authority: "self"} = p} ->
        resolve_space_one(%{p | authority: user_did}, collections)

      {:space, p} ->
        resolve_space_one(p, collections)

      other ->
        other
    end)
  end

  defp resolve_space_one(%{collection: [], type: type} = p, collections) when type != "*" do
    {:space, %{p | collection: collections.(type)}}
  end

  defp resolve_space_one(p, _), do: {:space, p}

  defp default_space_collections(nsid) do
    case Aerox.ATProto.Lexicon.Registry.get_def(Aerox.ATProto.Lexicon.default_registry(), nsid) do
      {:ok, %{"type" => "space", "collections" => cols}} when is_list(cols) -> cols
      _ -> []
    end
  end

  # ------------------------------------------------------------- include

  @doc """
  Upstream `IncludeScope.toPermissions`: the `repo`/`rpc` permissions of a
  permission-set lexicon that the including NSID's authority covers. `aud`
  substitutes for `inheritAud` rpc permissions.
  """
  @spec expand_include(%{nsid: String.t(), aud: String.t() | nil}, map) :: [permission]
  def expand_include(%{nsid: nsid, aud: aud}, %{
        "type" => "permission-set",
        "permissions" => perms
      }) do
    for perm <- perms,
        syn = lex_permission_syntax(perm, aud),
        p = parse(syn),
        allowed_include?(nsid, p),
        do: p
  end

  def expand_include(_, _), do: []

  defp lex_permission_syntax(%{"type" => "permission", "resource" => "repo"} = perm, _aud) do
    build("repo", List.wrap(perm["collection"]), [
      {"action", perm["action"] && List.wrap(perm["action"]), nil}
    ])
  end

  defp lex_permission_syntax(%{"type" => "permission", "resource" => "rpc"} = perm, aud) do
    cond do
      perm["aud"] not in [nil, "*"] ->
        nil

      perm["inheritAud"] == true and is_nil(perm["aud"]) and aud != nil ->
        build("rpc", List.wrap(perm["lxm"]), [{"aud", aud, nil}])

      # no aud and nothing to inherit: the rpc scope is invalid and dropped
      true ->
        build("rpc", List.wrap(perm["lxm"]), [{"aud", perm["aud"], nil}])
    end
  end

  # `spaceType` in JSON is `type` on the wire (`type` is the discriminator).
  defp lex_permission_syntax(%{"type" => "permission", "resource" => "space"} = perm, _aud) do
    build("space", perm["spaceType"], [
      {"authority", perm["authority"], nil},
      {"skey", perm["skey"], nil},
      {"collection", perm["collection"] && List.wrap(perm["collection"]), nil},
      {"action", perm["action"] && List.wrap(perm["action"]), nil},
      {"manage", perm["manage"] && List.wrap(perm["manage"]), nil}
    ])
  end

  defp lex_permission_syntax(_, _), do: nil

  defp allowed_include?(nsid, {:rpc, %{lxm: lxm}}),
    do: Enum.all?(lxm, &parent_authority?(nsid, &1))

  defp allowed_include?(nsid, {:repo, %{collection: c}}),
    do: Enum.all?(c, &parent_authority?(nsid, &1))

  # only the space type is authority-checked; collections may live elsewhere
  defp allowed_include?(nsid, {:space, %{type: type}}), do: parent_authority?(nsid, type)
  defp allowed_include?(_, _), do: false

  @doc "Upstream isParentAuthorityOf: the including lexicon's group prefix (up to its last dot) must prefix the other NSID."
  def parent_authority?(_lexicon, "*"), do: false

  def parent_authority?(lexicon, other) do
    case :binary.matches(lexicon, ".") do
      [] ->
        false

      matches ->
        {group_end, _} = List.last(matches)

        group_end < byte_size(other) - 1 and
          binary_part(other, 0, group_end + 1) == binary_part(lexicon, 0, group_end + 1)
    end
  end

  # ------------------------------------------------------------ evaluate

  defmodule Granted do
    @moduledoc "A granted scope string, parsed and expanded once (upstream `ScopePermissionsTransition`)."
    defstruct scopes: [], permissions: [], transition: MapSet.new(), atproto?: false

    @type t :: %__MODULE__{}
  end

  @doc """
  Parses a granted scope string (space separated). `include:` scopes are
  expanded through `lookup`, a function from NSID to the permission-set
  lexicon def (or nil); defaults to the vendored registry.
  """
  @spec grant(String.t() | nil, (String.t() -> map | nil)) :: Granted.t()
  def grant(scope_string, lookup \\ &default_lookup/1) do
    scopes = (scope_string || "") |> String.split(" ", trim: true) |> Enum.uniq()

    perms =
      Enum.flat_map(scopes, fn s ->
        case parse(s) do
          {:include, inc} -> expand_include(inc, lookup.(inc.nsid) || %{})
          nil -> []
          p -> [p]
        end
      end)

    %Granted{
      scopes: scopes,
      permissions: perms,
      transition:
        perms
        |> Enum.filter(&match?({:transition, _}, &1))
        |> Enum.map(&elem(&1, 1))
        |> MapSet.new(),
      atproto?: "atproto" in scopes
    }
  end

  @doc """
  Upstream `LexiconManager.buildTokenScope` plus the alpha's issuance-time
  resolution: the scope a token carries (and the token response's `scope`)
  is composed solely of granular permissions — every `include:` expanded
  from its permission set, `authority=self` resolved to the account, default
  collections filled in — so clients such as `bulletin` can evaluate it
  (`lookup` finds a permission set by NSID; the vendored registry by default)
  locally with `ScopePermissions`. Scopes without `include:` are returned
  as-is (upstream does the same), except that space scopes are still resolved.
  """
  @spec build_token_scope(String.t() | nil, String.t(), (String.t() -> map | nil)) :: String.t()
  def build_token_scope(scope_string, user_did, lookup \\ &default_lookup/1) do
    scopes = (scope_string || "") |> String.split(" ", trim: true) |> Enum.uniq()

    scopes
    |> Enum.flat_map(fn s ->
      case parse(s) do
        {:include, inc} ->
          expand_include(inc, lookup.(inc.nsid) || %{})
          |> resolve_space(user_did)
          |> Enum.map(&format/1)

        {:space, _} = p ->
          [p] |> resolve_space(user_did) |> Enum.map(&format/1)

        _ ->
          [s]
      end
    end)
    |> Enum.uniq()
    |> Enum.join(" ")
  end

  defp default_lookup(nsid) do
    case Aerox.ATProto.Lexicon.Registry.get_def(Aerox.ATProto.Lexicon.default_registry(), nsid) do
      {:ok, %{"type" => "permission-set"} = def} -> def
      _ -> nil
    end
  end

  @doc "Upstream `ScopePermissionsTransition.allows*`: transitional scopes first, then granular permissions."
  @spec allows?(Granted.t(), atom, map) :: boolean
  def allows?(%Granted{} = g, :account, %{attr: "email", action: "read"} = t),
    do: MapSet.member?(g.transition, "email") or any_match?(g, :account, t)

  def allows?(%Granted{} = g, resource, t) when resource in [:blob, :repo],
    do: MapSet.member?(g.transition, "generic") or any_match?(g, resource, t)

  def allows?(%Granted{} = g, :rpc, %{lxm: lxm} = t) do
    generic = MapSet.member?(g.transition, "generic")
    chat = MapSet.member?(g.transition, "chat.bsky")

    cond do
      generic and lxm == "*" -> true
      generic and not String.starts_with?(lxm, "chat.bsky.") -> true
      chat and String.starts_with?(lxm, "chat.bsky.") -> true
      true -> any_match?(g, :rpc, t)
    end
  end

  def allows?(%Granted{} = g, resource, t), do: any_match?(g, resource, t)

  defp any_match?(g, resource, t), do: Enum.any?(g.permissions, &matches?(&1, resource, t))

  @doc "`:ok` or `{:error, {:scope_missing, needed}}` (upstream `ScopeMissingError`)."
  def assert(%Granted{} = g, resource, t) do
    if allows?(g, resource, t), do: :ok, else: {:error, {:scope_missing, needed_for(resource, t)}}
  end
end
