defmodule Aerox.PDS.Handle.Slurs do
  @moduledoc """
  Explicit-slur screening for handles and record keys, ported verbatim from
  upstream `pds/src/handle/explicit-slurs.ts` (which credits
  github.com/Blank-Cheque/Slurs). The patterns live in
  `priv/explicit_slurs.txt`, one per line, and are compiled at build time.
  Checked against the handle as given and with dots, dashes and underscores
  removed, as upstream does.
  """

  @file_path Path.expand("../../../priv/explicit_slurs.txt", __DIR__)
  @external_resource @file_path
  @patterns @file_path |> File.read!() |> String.split("\n", trim: true)

  @spec explicit_slur?(String.t()) :: boolean
  def explicit_slur?(handle) when is_binary(handle) do
    stripped =
      handle |> String.replace(".", "") |> String.replace("-", "") |> String.replace("_", "")

    Enum.any?(regexes(), fn re -> Regex.match?(re, handle) or Regex.match?(re, stripped) end)
  end

  defp regexes do
    case :persistent_term.get({__MODULE__, :regexes}, nil) do
      nil ->
        compiled = Enum.map(@patterns, &Regex.compile!(&1, "u"))
        :persistent_term.put({__MODULE__, :regexes}, compiled)
        compiled

      compiled ->
        compiled
    end
  end
end
