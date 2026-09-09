defmodule Aerox.PLC.Directory do
  @moduledoc """
  The did:plc directory's storage and admission (DESIGN §2, §14.2 point 7):
  `submit/3` validates an operation against the DID's history under a row
  lock and records nullifications; reads serve `/`, `/data`, `/log`,
  `/log/audit`, `/log/last` and `/export`. `remove_invalid_ops/2` is the
  audited, alerting admin path — never routine.

  Transcribed from `did-method-plc/packages/server/src/db/index.ts`.
  """
  import Ecto.Query
  require Logger
  alias Aerox.PLC.{AdminLog, Did, Operation, Operations, Repo}

  @hour_limit 10
  @day_limit 30
  @week_limit 100

  @type error :: {:error, {:bad_request | :conflict | :not_found, String.t()}}

  # -------------------------------------------------------------- write

  @doc "Validates and stores `op` for `did` at `now` (upstream `validateAndAddOp`)."
  @spec submit(String.t(), map, DateTime.t()) :: {:ok, Operation.t()} | error
  def submit(did, op, now \\ DateTime.utc_now()) do
    now = %{now | microsecond: {elem(now.microsecond, 0), 6}}

    with :ok <- check_did(did),
         :ok <- wrap(Operations.check_incoming_op(op)) do
      Repo.transaction(fn ->
        lock_did(did)
        ops = indexed_ops(did, false)

        with {:ok, %{nullified: nullified, prev: prev}} <- validate(did, ops, op, now),
             :ok <- if(nullified == [], do: rate_limit(ops, now), else: :ok),
             {:ok, row} <- insert(did, op, now),
             :ok <- nullify(did, nullified),
             :ok <- check_prev(did, prev) do
          row
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  defp validate(did, ops, op, now) do
    case Operations.assure_valid_next_op(did, ops, op, now) do
      {:ok, result} -> {:ok, result}
      {:error, %Operations.Error{message: msg}} -> {:error, {:bad_request, msg}}
    end
  end

  defp lock_did(did) do
    case Repo.one(from(d in Did, where: d.did == ^did, lock: "FOR UPDATE")) do
      nil -> Repo.insert!(%Did{did: did})
      _ -> :ok
    end
  end

  defp insert(did, op, now) do
    cid = op |> Operations.cid() |> to_string()

    case Repo.insert(%Operation{
           did: did,
           cid: cid,
           operation: op,
           nullified: false,
           created_at: now
         }) do
      {:ok, row} -> {:ok, row}
      {:error, _} -> {:error, {:conflict, "operation already exists: #{cid}"}}
    end
  end

  defp nullify(_did, []), do: :ok

  defp nullify(did, cids) do
    strs = Enum.map(cids, &to_string/1)

    Repo.update_all(from(o in Operation, where: o.did == ^did and o.cid in ^strs),
      set: [nullified: true]
    )

    :ok
  end

  # After the insert the proposed op must be the newest and its `prev` the
  # one before it; a concurrent submit that slipped past would break that.
  defp check_prev(did, prev) do
    recent =
      Repo.all(
        from(o in Operation,
          where: o.did == ^did and not o.nullified,
          order_by: [desc: o.created_at, desc: o.cid],
          limit: 2,
          select: o.cid
        )
      )

    case {prev, recent} do
      {nil, [_]} ->
        :ok

      {%{} = prev, [_, second]} ->
        if to_string(prev) == second,
          do: :ok,
          else: {:error, {:conflict, "Proposed prev does not match the most recent operation"}}

      _ ->
        {:error, {:conflict, "Proposed prev does not match the most recent operation"}}
    end
  end

  # upstream enforceOpsRateLimit: counts of ops within the last hour/day/week.
  defp rate_limit(ops, now) do
    windows = [
      {3600, @hour_limit, "hour"},
      {86_400, @day_limit, "day"},
      {7 * 86_400, @week_limit, "week"}
    ]

    Enum.find_value(windows, :ok, fn {secs, limit, name} ->
      count = Enum.count(ops, &(DateTime.diff(now, &1.created_at) < secs))

      if count >= limit,
        do: {:error, {:bad_request, "To many operations within last #{name} (max #{limit})"}},
        else: nil
    end)
  end

  defp check_did(did),
    do:
      if(Operations.valid_plc_did?(did),
        do: :ok,
        else: {:error, {:bad_request, "Invalid DID: #{did}"}}
      )

  defp wrap(:ok), do: :ok
  defp wrap({:error, msg}), do: {:error, {:bad_request, msg}}

  # --------------------------------------------------------------- read

  @doc "Ops for a DID, oldest first; nullified ones only when `include_nullified`."
  @spec indexed_ops(String.t(), boolean) :: [Operations.indexed()]
  def indexed_ops(did, include_nullified) do
    q = from(o in Operation, where: o.did == ^did, order_by: [asc: o.created_at, asc: o.cid])
    q = if include_nullified, do: q, else: where(q, [o], not o.nullified)
    q |> Repo.all() |> Enum.map(&Operation.to_indexed/1)
  end

  @spec audit_log(String.t()) :: [map]
  def audit_log(did) do
    from(o in Operation, where: o.did == ^did, order_by: [asc: o.created_at, asc: o.cid])
    |> Repo.all()
    |> Enum.map(&Operation.to_exported/1)
  end

  @spec last_op(String.t()) :: map | nil
  def last_op(did) do
    from(o in Operation,
      where: o.did == ^did and not o.nullified,
      order_by: [desc: o.created_at, desc: o.cid],
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil -> nil
      row -> row.operation
    end
  end

  @doc "The current document data, `{:error, :not_found}` for unknown DIDs and `{:error, :tombstoned}` after a tombstone."
  @spec document_data(String.t()) ::
          {:ok, Operations.document_data()} | {:error, :not_found | :tombstoned}
  def document_data(did) do
    case last_op(did) do
      nil -> {:error, :not_found}
      op -> if data = Operations.op_to_data(did, op), do: {:ok, data}, else: {:error, :tombstoned}
    end
  end

  @spec did_document(String.t()) :: {:ok, map} | {:error, :not_found | :tombstoned}
  def did_document(did) do
    with {:ok, data} <- document_data(did), do: {:ok, Operations.format_did_doc(data)}
  end

  @doc "`/export`: up to `count` (≤ 1000) ops after a timestamp (by createdAt, cid) or after a seq number."
  @spec export(pos_integer, DateTime.t() | integer | nil) :: [map]
  def export(count, after_ \\ nil) do
    count = count |> max(1) |> min(1000)

    case after_ do
      seq when is_integer(seq) ->
        from(o in Operation, where: o.seq > ^seq, order_by: [asc: o.seq], limit: ^count)
        |> Repo.all()
        |> Enum.map(&Operation.to_exported(&1, seq: true))

      %DateTime{} = ts ->
        from(o in Operation,
          where: o.created_at > ^ts,
          order_by: [asc: o.created_at, asc: o.cid],
          limit: ^count
        )
        |> Repo.all()
        |> Enum.map(&Operation.to_exported/1)

      nil ->
        from(o in Operation, order_by: [asc: o.created_at, asc: o.cid], limit: ^count)
        |> Repo.all()
        |> Enum.map(&Operation.to_exported/1)
    end
  end

  @spec operation_count() :: non_neg_integer
  def operation_count, do: Repo.aggregate(Operation, :count)

  # -------------------------------------------------------------- admin

  @doc """
  Removes an invalid operation and everything after it (upstream
  `removeInvalidOps`), refusing valid ops and DIDs with prior nullifications.
  Every removed op is written to `admin_logs` and logged at error level so
  it alerts (DESIGN §14.2 point 7).
  """
  @spec remove_invalid_ops(String.t(), String.t()) :: {:ok, [map]} | error
  def remove_invalid_ops(did, cid) do
    Repo.transaction(fn ->
      case Repo.one(from(d in Did, where: d.did == ^did, lock: "FOR UPDATE")) do
        nil -> Repo.rollback({:bad_request, "did does not exist"})
        _ -> :ok
      end

      ops = indexed_ops(did, true)

      with {:ok, index} <- find_cid(ops, cid),
           {before, [suspect | _] = tail} = Enum.split(ops, index),
           :ok <-
             if(Enum.any?(before, & &1.nullified),
               do:
                 {:error,
                  {:bad_request,
                   "removing ops from DIDs with prior nullifications is not currently supported"}},
               else: :ok
             ),
           :ok <-
             if(valid_against?(did, before, suspect),
               do: {:error, {:bad_request, "valid operations cannot be removed"}},
               else: :ok
             ) do
        for op <- tail do
          Repo.delete_all(
            from(o in Operation, where: o.did == ^did and o.cid == ^to_string(op.cid))
          )

          Repo.insert!(%AdminLog{
            type: "removeInvalidOps",
            data: %{"did" => did, "cid" => to_string(op.cid)}
          })

          Logger.error(
            "plc: removed invalid operation #{op.cid} for #{did} (admin action, audited)"
          )
        end

        Enum.map(tail, fn op ->
          %{
            "did" => did,
            "operation" => op.operation,
            "cid" => to_string(op.cid),
            "nullified" => op.nullified,
            "createdAt" => Aerox.ATProto.Syntax.format_datetime(op.created_at)
          }
        end)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp find_cid(ops, cid) do
    case Enum.find_index(ops, &(to_string(&1.cid) == cid)) do
      nil -> {:error, {:bad_request, "operation does not exist"}}
      i -> {:ok, i}
    end
  end

  defp valid_against?(did, before, suspect) do
    match?(
      {:ok, _},
      Operations.assure_valid_next_op(
        did,
        Enum.reject(before, & &1.nullified),
        suspect.operation,
        suspect.created_at
      )
    )
  end
end
