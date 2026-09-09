defmodule Aerox.PDS.Space.Uri do
  @moduledoc """
  Space URIs (DESIGN §12, upstream `space-uri.ts`) in both wire forms:

  * branch: `ats://<spaceDid>/<spaceType>/<skey>[/<userDid>/<collection>/<rkey>]`
  * alpha (`bulletin`, `@atproto/lex` `space-ref`): `at://<spaceDid>/space/<spaceType>/<skey>[/…]`

  `parse/1` returns the parts plus `space`, the space portion in the
  **alpha form** (`at://…/space/…`) whatever the caller used: it is the
  storage key and the `space` field of every commit context, so both forms
  name one repo. A record URI is `"\#{space}/\#{did}/\#{collection}/\#{rkey}"`.
  """
  alias Aerox.ATProto.Syntax

  @type t :: %{
          did: String.t(),
          type: String.t(),
          skey: String.t(),
          user_did: String.t() | nil,
          collection: String.t() | nil,
          rkey: String.t() | nil,
          space: String.t(),
          form: :ats | :at
        }

  @doc "Parses a space URI (either form); the type and skey are required."
  @spec parse(term) :: {:ok, t} | {:error, String.t()}
  def parse(input) when is_binary(input) do
    with {:ok, g} <- Syntax.parse_space_uri(input),
         true <-
           (g.space_type != nil and g.skey != nil) || {:error, "space-uri needs a type and key"} do
      form = if String.starts_with?(input, "at://"), do: :at, else: :ats

      {:ok,
       %{
         did: g.authority,
         type: g.space_type,
         skey: g.skey,
         user_did: g.user_did,
         collection: g.collection,
         rkey: g.rkey,
         space: format(g.authority, g.space_type, g.skey, :at),
         form: form
       }}
    else
      {:error, _} = e -> e
    end
  end

  def parse(_), do: {:error, "space-uri must be a string"}

  @doc "The space URI for its parts, in the alpha (`at://…/space/…`) form by default."
  @spec format(String.t(), String.t(), String.t(), :ats | :at) :: String.t()
  def format(did, type, skey, form \\ :at)
  def format(did, type, skey, :at), do: "at://#{did}/space/#{type}/#{skey}"
  def format(did, type, skey, :ats), do: "ats://#{did}/#{type}/#{skey}"

  @doc "The record URI inside a space."
  @spec record_uri(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def record_uri(space, did, collection, rkey), do: "#{space}/#{did}/#{collection}/#{rkey}"

  @doc "The space DID (authority) of a space URI, or nil."
  @spec space_did(String.t()) :: String.t() | nil
  def space_did(uri) do
    case parse(uri) do
      {:ok, %{did: did}} -> did
      _ -> nil
    end
  end
end
