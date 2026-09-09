defmodule Aerox.AppView.Cursor do
  @moduledoc """
  Upstream's `TimeCidKeyset`: a cursor is `<epoch ms>::<cid>` over
  `(sort_at desc, cid desc)`. `parse/1` returns `{datetime, cid}` or nil;
  `pack/2` builds one from the last row of a page.
  """

  @spec parse(String.t() | nil) :: {DateTime.t(), String.t()} | nil
  def parse(nil), do: nil
  def parse(""), do: nil

  def parse(cursor) when is_binary(cursor) do
    with [ms, cid] <- String.split(cursor, "::", parts: 2),
         {ms, ""} <- Integer.parse(ms),
         {:ok, dt} <- DateTime.from_unix(ms, :millisecond) do
      {%{dt | microsecond: {elem(dt.microsecond, 0), 6}}, cid}
    else
      _ -> nil
    end
  end

  @spec pack(DateTime.t(), String.t()) :: String.t()
  def pack(%DateTime{} = dt, cid), do: "#{DateTime.to_unix(dt, :millisecond)}::#{cid}"

  @doc "Upstream `clearlyBadCursor`: a cursor that cannot be ours."
  def clearly_bad?(nil), do: false
  # clients (ouranos) send `cursor=` for the first page: an empty cursor is no cursor
  def clearly_bad?(""), do: false
  def clearly_bad?(cursor), do: is_nil(parse(cursor))

  @doc """
  Applies the keyset to an Ecto query on `sort_at`/`cid` fields of the first
  binding, and limits it. Rows with `sort_at` at the cursor are broken by cid.

  `sort_at` is stored with microseconds but the cursor carries milliseconds
  (upstream's format), so both the ordering and the comparison truncate to
  the millisecond: otherwise rows in the cursor's millisecond fall between
  pages.
  """
  defmacro paginate(query, cursor, limit) do
    quote do
      import Ecto.Query

      q = unquote(query)

      q =
        case Aerox.AppView.Cursor.parse(unquote(cursor)) do
          nil ->
            q

          {dt, cid} ->
            where(
              q,
              [r],
              fragment("date_trunc('milliseconds', ?)", r.sort_at) < ^dt or
                (fragment("date_trunc('milliseconds', ?)", r.sort_at) == ^dt and r.cid < ^cid)
            )
        end

      q
      |> order_by([r], desc: fragment("date_trunc('milliseconds', ?)", r.sort_at), desc: r.cid)
      |> limit(^unquote(limit))
    end
  end

  @doc "The cursor for the next page after `rows` (each with sort_at and cid), or nil when the page is short."
  def next(rows, limit) do
    if length(rows) >= limit and rows != [] do
      last = List.last(rows)
      pack(last.sort_at, last.cid)
    end
  end
end
