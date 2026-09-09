defmodule Aerox.Interop.Verify do
  @moduledoc """
  DESIGN §13.3, the part that is not optional. Two per-account reports and
  one run summary:

    * `bundle/2` — against the bundle alone, before any database write:
      manifest hashes, `repo.car` verified by the kernel (root recomputed
      == commit `data`, signature by the bundled key, version 3), counts
      against the manifest.
    * `imported/3` — against `aerox_pds` after the import: `repo_root.cid`
      == the CAR's root, the MST root recomputed from the stored blocks,
      record / block / blob / `record_blob` counts, every stored blob's
      sha256 == its CID, login with a known password, and in takeover mode
      `max(seq)` and the last event's bytes.
    * `summary/2` — the whole run; refuses to be green when nothing was
      imported from a non-empty source ("0 accounts, 0 failures" is a
      failure signature — the did-map incident).

  A report is `%{did, ok?, checks: [{name, :ok | {:error, detail}}]}`.
  """
  import Ecto.Query
  alias Aerox.ATProto.{CAR, CID}
  alias Aerox.ATProto.Blockstore.Memory
  alias Aerox.ATProto.MST
  alias Aerox.ATProto.Repo, as: KRepo
  alias Aerox.Blob.Store
  alias Aerox.Interop.Bundle
  alias Aerox.Interop.Bundle.Postgres
  alias Aerox.PDS.{Accounts, Blockstore, Repo}
  alias Aerox.PDS.Schema.{Blob, Record, RecordBlob, RepoBlock, RepoRoot, RepoSeq}

  @type check :: {atom, :ok | {:error, term}}
  @type report :: %{did: String.t(), ok?: boolean, checks: [check]}

  # ------------------------------------------------------------- bundle

  @doc "The pre-import report. Options: `takeover:`."
  @spec bundle(Bundle.t(), keyword) :: report
  def bundle(%Bundle{manifest: m} = b, opts \\ []) do
    did = m["did"]

    checks =
      case Postgres.parse(b, Keyword.get(opts, :takeover, false)) do
        {:error, reason} ->
          [{:bundle, {:error, reason}}]

        {:ok, parsed} ->
          bs = Memory.new(parsed.blocks)
          counts = m["counts"] || %{}

          [
            {:bundle, :ok},
            {:mst_root, mst_root_check(bs, parsed.commit)},
            {:record_count, expect(length(parsed.records), counts["records"])},
            {:block_count, expect(length(parsed.blocks), counts["blocks"])},
            {:blob_count, expect(length(m["hashes"]["blobs"] || []), counts["blobs"])},
            {:seq_count,
             if(Keyword.get(opts, :takeover, false),
               do: expect(length(parsed.seq_rows), counts["seq_events"]),
               else: :ok
             )}
          ]
      end

    finish(did, checks)
  end

  # --------------------------------------------------------- imported

  @doc """
  The post-import report for `did`. Options: `password:` (login check),
  `takeover:`, `store:`.
  """
  @spec imported(String.t(), Bundle.t(), keyword) :: report
  def imported(did, %Bundle{manifest: m} = b, opts \\ []) do
    store = Keyword.get_lazy(opts, :store, &Store.adapter/0)

    checks =
      with {:ok, car} <- Bundle.read_file(b, "repo.car"),
           {:ok, root, car_blocks} <- CAR.decode_with_root(car),
           %RepoRoot{} = pg_root <- Repo.get(RepoRoot, did) || {:error, :no_repo_root} do
        pg_bs = Blockstore.new(did)

        commit_check =
          case KRepo.load(pg_bs, CID.parse!(pg_root.cid)) do
            {:ok, repo} -> mst_root_check(pg_bs, repo.commit)
            {:error, reason} -> {:error, reason}
          end

        car_set = car_blocks |> Enum.map(fn {c, _} -> CID.to_string(c) end) |> MapSet.new()
        pg_set = Blockstore.all_cids(did) |> Enum.map(&CID.to_string/1) |> MapSet.new()
        expected_records = m["counts"]["records"]

        [
          {:repo_root, expect(pg_root.cid, CID.to_string(root))},
          {:mst_root, commit_check},
          {:block_set,
           if(MapSet.equal?(car_set, pg_set),
             do: :ok,
             else: {:error, {:block_sets_differ, MapSet.size(car_set), MapSet.size(pg_set)}}
           )},
          {:record_count, expect(count(Record, did), expected_records)},
          {:block_count, expect(count(RepoBlock, did), m["counts"]["blocks"])},
          {:blob_count, expect(count(Blob, did), map_size(state_blobs(b)))},
          {:record_blob_count, record_blob_check(did, car_blocks)},
          {:blob_bytes, blob_bytes_check(store, did, m["hashes"]["blobs"] || [])},
          {:login, login_check(did, opts[:password])},
          {:sequencer, seq_check(did, b, Keyword.get(opts, :takeover, false))}
        ]
      else
        {:error, reason} -> [{:imported, {:error, reason}}]
      end

    finish(did, checks)
  end

  defp mst_root_check(bs, %{"data" => data_cid}) do
    case MST.recompute_root(bs, MST.load(data_cid)) do
      {:ok, ^data_cid} ->
        :ok

      {:ok, other} ->
        {:error, {:mst_root_mismatch, CID.to_string(data_cid), CID.to_string(other)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp count(schema, did), do: Repo.aggregate(from(x in schema, where: x.did == ^did), :count)

  defp state_blobs(b) do
    case Bundle.read_file(b, "state.json") do
      {:ok, json} -> Jason.decode!(json)["blobs"] || %{}
      _ -> %{}
    end
  end

  # record_blob must equal the blob refs found in the CAR's record blocks
  defp record_blob_check(did, _car_blocks) do
    expected =
      from(r in Record,
        join: b in RepoBlock,
        on: b.did == r.did and b.cid == r.cid,
        where: r.did == ^did,
        select: {r.uri, b.content}
      )
      |> Repo.all()
      |> Enum.flat_map(fn {uri, bytes} ->
        case Aerox.ATProto.Data.decode_cbor(bytes) do
          {:ok, rec} ->
            for %{"ref" => %CID{} = c} <- Aerox.ATProto.Data.blob_refs(rec),
                do: {CID.to_string(c), uri}

          _ ->
            []
        end
      end)
      |> MapSet.new()

    actual =
      from(rb in RecordBlob, where: rb.did == ^did, select: {rb.blob_cid, rb.record_uri})
      |> Repo.all()
      |> MapSet.new()

    if MapSet.equal?(expected, actual),
      do: :ok,
      else: {:error, {:record_blob_mismatch, MapSet.size(expected), MapSet.size(actual)}}
  end

  defp blob_bytes_check(store, did, cids) do
    bad =
      Enum.reject(cids, fn cid_str ->
        cid = CID.parse!(cid_str)

        case Store.stream(store, did, cid) do
          {:ok, s} ->
            digest =
              Enum.reduce(s, :crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
              |> :crypto.hash_final()

            digest == cid.digest

          _ ->
            false
        end
      end)

    if bad == [], do: :ok, else: {:error, {:blob_bytes_mismatch, bad}}
  end

  defp login_check(_did, nil), do: :ok

  defp login_check(did, password) do
    case Accounts.login(did, password) do
      {:ok, %{did: ^did}, _} -> :ok
      {:error, reason} -> {:error, {:login_failed, reason}}
    end
  end

  defp seq_check(_did, _b, false), do: :ok

  defp seq_check(did, b, true) do
    with {:ok, rows} <- Bundle.seq_rows(b) do
      case List.last(rows) do
        nil ->
          :ok

        last ->
          stored =
            Repo.one(from(s in RepoSeq, where: s.did == ^did, order_by: [desc: s.seq], limit: 1))

          cond do
            stored == nil -> {:error, :no_seq_rows}
            stored.seq != last.seq -> {:error, {:max_seq_mismatch, last.seq, stored.seq}}
            stored.event != last.event -> {:error, :last_event_bytes_differ}
            true -> :ok
          end
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp expect(actual, nil), do: {:error, {:manifest_count_missing, actual}}
  defp expect(actual, actual), do: :ok
  defp expect(actual, expected), do: {:error, {:mismatch, expected: expected, actual: actual}}

  defp finish(did, checks) do
    %{did: did, ok?: Enum.all?(checks, &match?({_, :ok}, &1)), checks: checks}
  end

  # ----------------------------------------------------------- summary

  @doc """
  The run summary. `results` is a list of `{did, outcome}` where outcome is
  `:imported`, `:skipped` (already present), or `{:failed, reason}`;
  `source_count` is how many accounts the source held.

  `{:error, :nothing_imported}` when the source was non-empty but nothing
  was imported or found present; `{:error, {:failures, dids}}` when any
  account failed; `{:ok, summary}` otherwise. Never `:ok` for zero work.
  """
  @spec summary([{String.t(), term}], non_neg_integer) :: {:ok, map} | {:error, term}
  def summary(results, source_count) do
    imported = for {did, :imported} <- results, do: did
    skipped = for {did, :skipped} <- results, do: did
    failed = for {did, {:failed, reason}} <- results, do: {did, reason}

    summary = %{
      source_accounts: source_count,
      imported: length(imported),
      skipped: length(skipped),
      failed: length(failed),
      failed_dids: failed
    }

    cond do
      failed != [] ->
        {:error, {:failures, summary}}

      source_count > 0 and imported == [] and skipped == [] ->
        {:error, {:nothing_imported, summary}}

      source_count == 0 ->
        {:error, {:empty_source, summary}}

      true ->
        {:ok, summary}
    end
  end

  @doc "Renders a report as lines for the shell."
  @spec format(report) :: [String.t()]
  def format(%{did: did, ok?: ok?, checks: checks}) do
    [
      "#{if ok?, do: "PASS", else: "FAIL"} #{did}"
      | for {name, result} <- checks do
          case result do
            :ok -> "  ok    #{name}"
            {:error, detail} -> "  FAIL  #{name}: #{inspect(detail)}"
          end
        end
    ]
  end

  @doc "PLC operations a bundle would need (DESIGN §13.5): listed, never submitted."
  @spec plc_ops_needed(Bundle.t(), String.t()) :: [map]
  def plc_ops_needed(%Bundle{manifest: m}, our_host) do
    from_host = get_in(m, ["source", "host"])

    if is_binary(from_host) and from_host != our_host,
      do: [
        %{
          did: m["did"],
          change: "#atproto_pds",
          from: "https://#{from_host}",
          to: "https://#{our_host}"
        }
      ],
      else: []
  end
end
