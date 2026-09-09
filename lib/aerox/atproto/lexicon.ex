defmodule Aerox.ATProto.Lexicon do
  @moduledoc """
  Lexicon interpreter entry points (DESIGN §6): validation of records, XRPC
  parameters/bodies and stream messages against an explicit registry, and
  the PDS's three-state record admission (§6.3): `validate: false` skips,
  `validate: true` refuses unknown lexicons, unset validates known ones and
  admits unknown ones tagged `:unknown`.
  """
  alias Aerox.ATProto.Lexicon.{Registry, Validator, Vendored}

  @type status :: :valid | :unknown

  @doc "The compile-time registry of vendored lexicons."
  @spec default_registry() :: Registry.t()
  def default_registry, do: Vendored.registry()

  defdelegate validate(registry, ref, value), to: Validator
  defdelegate validate_record(registry, nsid, record), to: Validator
  defdelegate validate_params(registry, nsid, params), to: Validator
  defdelegate validate_input(registry, nsid, value), to: Validator
  defdelegate validate_output(registry, nsid, value), to: Validator
  defdelegate validate_message(registry, nsid, value), to: Validator
  defdelegate known?(registry, ref), to: Registry

  @doc """
  Upstream `prepare.ts`'s three-state `validate`. Returns `{:ok, :valid}`,
  `{:ok, :unknown}`, `{:ok, :skipped}` or `{:error, reason}`.
  """
  @spec record_status(Registry.t(), map, boolean | nil) ::
          {:ok, status | :skipped} | {:error, term}
  def record_status(_registry, _record, false), do: {:ok, :skipped}

  def record_status(registry, %{"$type" => type} = record, validate) when is_binary(type) do
    if Registry.known?(registry, type) do
      case Validator.validate_record(registry, type, record) do
        {:ok, _} -> {:ok, :valid}
        {:error, {msg, path}} -> {:error, {:invalid_record, msg, path}}
      end
    else
      if validate == true, do: {:error, {:unknown_lexicon, type}}, else: {:ok, :unknown}
    end
  end

  def record_status(_registry, _record, _validate), do: {:error, :missing_type}

  @doc "The record-key rule of a record lexicon: `\"tid\"`, `\"nsid\"`, `\"any\"` or `\"literal:<value>\"`."
  @spec record_key_rule(Registry.t(), String.t()) :: {:ok, String.t()} | :error
  def record_key_rule(registry, nsid) do
    case Registry.get_def(registry, nsid) do
      {:ok, %{"type" => "record"} = def} -> {:ok, Map.get(def, "key", "any")}
      _ -> :error
    end
  end

  @doc "Checks an rkey against a record lexicon's key rule."
  @spec valid_record_key?(Registry.t(), String.t(), String.t()) :: boolean
  def valid_record_key?(registry, nsid, rkey) do
    case record_key_rule(registry, nsid) do
      {:ok, "tid"} -> Aerox.ATProto.Syntax.valid_tid?(rkey)
      {:ok, "nsid"} -> Aerox.ATProto.Syntax.valid_nsid?(rkey)
      {:ok, "literal:" <> lit} -> rkey == lit
      {:ok, _any} -> Aerox.ATProto.Syntax.valid_record_key?(rkey)
      :error -> Aerox.ATProto.Syntax.valid_record_key?(rkey)
    end
  end
end
