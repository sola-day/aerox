defmodule Aerox.Interop.ReferencePds.Sqlite do
  @moduledoc "Thin exqlite helpers: typed rows in, typed rows out, no text round-trips for blobs (DESIGN §13.2)."

  alias Exqlite.Sqlite3

  @spec open(Path.t()) :: {:ok, reference} | {:error, term}
  def open(path), do: Sqlite3.open(path)

  @spec close(reference) :: :ok
  def close(conn), do: Sqlite3.close(conn)

  @doc "Runs `sql` with `params`; returns the rows as maps keyed by column name."
  @spec query(reference, String.t(), list) :: [map]
  def query(conn, sql, params \\ []) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    :ok = Sqlite3.bind(stmt, params)
    {:ok, cols} = Sqlite3.columns(conn, stmt)
    {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    Enum.map(rows, fn row -> cols |> Enum.zip(row) |> Map.new() end)
  end

  @doc "Runs a statement with params (INSERT/UPDATE)."
  @spec exec(reference, String.t(), list) :: :ok
  def exec(conn, sql, params \\ []) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    :ok = Sqlite3.bind(stmt, params)
    :done = Sqlite3.step(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
  end

  @doc "Runs raw SQL (DDL, pragmas)."
  @spec execute(reference, String.t()) :: :ok
  def execute(conn, sql), do: Sqlite3.execute(conn, sql)

  @doc "`INSERT OR REPLACE` of a map's keys (upstream camelCase column names) into `table`."
  @spec upsert(reference, String.t(), map) :: :ok
  def upsert(conn, table, row) do
    cols = Map.keys(row)
    names = Enum.map_join(cols, ", ", &("\"" <> &1 <> "\""))
    marks = Enum.map_join(cols, ", ", fn _ -> "?" end)
    sql = "INSERT OR REPLACE INTO \"" <> table <> "\" (" <> names <> ") VALUES (" <> marks <> ")"
    exec(conn, sql, Enum.map(cols, &row[&1]))
  end

  @doc "Runs `fun` inside a transaction."
  @spec transaction(reference, (-> any)) :: any
  def transaction(conn, fun) do
    :ok = execute(conn, "BEGIN")

    try do
      result = fun.()
      :ok = execute(conn, "COMMIT")
      result
    rescue
      e ->
        execute(conn, "ROLLBACK")
        reraise e, __STACKTRACE__
    end
  end

  @doc "Does the table exist?"
  @spec table?(reference, String.t()) :: boolean
  def table?(conn, name),
    do: query(conn, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [name]) != []

  @doc "SQLite integer flags → booleans and back."
  def bool(1), do: true
  def bool(true), do: true
  def bool(_), do: false
  def int(true), do: 1
  def int(_), do: 0
end
