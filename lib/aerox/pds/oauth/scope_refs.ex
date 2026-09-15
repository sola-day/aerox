defmodule Aerox.PDS.OAuth.ScopeRefs do
  @moduledoc """
  Scope references (`com.atproto.temp.dereferenceScope`; upstream PDS
  `ScopeReferenceGetter`). A token scope with every `include:` expanded can
  run to kilobytes, which every request would then carry in its access token.
  Past `@inline_max` bytes the token's `scope` claim becomes `ref:<cid>` —
  the CID (raw codec) of the scope string — and the string is stored here;
  the resource server dereferences it, and so can anyone holding the
  reference, through `dereferenceScope`. The token *response* keeps the full
  scope, since clients evaluate it locally.
  """
  alias Aerox.ATProto.CID
  alias Aerox.PDS.Repo
  alias Aerox.PDS.Schema.OAuthScopeRef

  @inline_max 1024
  @prefix "ref:"

  @doc "The scope as a token claim: itself, or a reference to it once it is long."
  @spec compact(String.t()) :: String.t()
  def compact(scope) when byte_size(scope) <= @inline_max, do: scope

  def compact(scope) do
    ref = @prefix <> CID.to_string(CID.for_raw(scope))

    Repo.insert_all(OAuthScopeRef, [%{ref: ref, scope: scope, created_at: DateTime.utc_now()}],
      on_conflict: :nothing
    )

    ref
  end

  @doc "Is this claim a reference (`ref:` and no spaces)?"
  def reference?(@prefix <> rest), do: not String.contains?(rest, " ")
  def reference?(_), do: false

  @doc "The scope a claim stands for."
  @spec dereference(String.t() | nil) ::
          {:ok, String.t() | nil} | {:error, :invalid_scope_reference}
  def dereference(scope) do
    if reference?(scope) do
      case Repo.get(OAuthScopeRef, scope) do
        %OAuthScopeRef{scope: full} -> {:ok, full}
        nil -> {:error, :invalid_scope_reference}
      end
    else
      {:ok, scope}
    end
  end
end
