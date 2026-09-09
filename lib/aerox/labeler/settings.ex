defmodule Aerox.Labeler.Settings do
  @moduledoc """
  `labeler.setting`: the values `Aerox.Labeler.Setup` persists so the
  labeler knows its own DID and key at boot without configuration. Reads
  are memoised in `:persistent_term` (the DID is consulted on every
  request); `put/2` refreshes the memo.
  """
  alias Aerox.Labeler.Repo
  alias Aerox.Labeler.Schema.Setting

  @spec get(String.t()) :: String.t() | nil
  def get(key) do
    case :persistent_term.get({__MODULE__, key}, :unset) do
      :unset ->
        value = read(key)
        # only memoise a value: a missing setting may be written later
        if value, do: :persistent_term.put({__MODULE__, key}, value)
        value

      value ->
        value
    end
  end

  @spec put(String.t(), String.t()) :: :ok
  def put(key, value) when is_binary(value) do
    Repo.insert_all(
      Setting,
      [%{key: key, value: value, updated_at: DateTime.utc_now()}],
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: [:key]
    )

    :persistent_term.put({__MODULE__, key}, value)
    :ok
  end

  @doc "Forgets the memo (tests)."
  def forget(key), do: :persistent_term.erase({__MODULE__, key})

  defp read(key) do
    case Repo.get(Setting, key) do
      %Setting{value: v} -> v
      nil -> nil
    end
  rescue
    # no repo running (the labeler service is disabled on this node)
    _ -> nil
  end
end
