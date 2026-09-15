defmodule Aerox.Jetstream.Importer do
  @moduledoc """
  Operator timestamp imports (docs/README.md §8): a CSV of AT URIs and the
  display times an earlier indexer recorded becomes `indexed_at` on the
  matching rows.

  A job (one at a time) parses the file under the import directory — header
  `uri,timestamp,scope,cid` in any order, `scope` `all_versions` (default) or
  `specific_version` with the version's `cid`; a bad row is skipped and
  counted, an unknown or duplicate column or an unclosed quote fails the file
  — into `timestamp_rule` (last write wins), which the writer applies to every
  row appended from then on. It then seals the active segment and patches the
  sealed segments: those whose DID bloom may hold a rule's DID are rewritten
  with the imported `indexed_at` on matching create/update/resync rows,
  checkpointed per segment so a restarted job resumes. Re-running a file
  changes nothing more.
  """
  use GenServer
  import Ecto.Query
  require Logger
  alias Aerox.ATProto.Syntax
  alias Aerox.Jetstream.{Compactor, Config, Convert, Event, Gloom, Manifest, Repo, Store, Writer}
  alias Aerox.Jetstream.Schema.{ImportJob, TimestampRule}

  @columns ~w(uri timestamp scope cid)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Submits a job for `path` (relative to, or absolute inside, the import directory)."
  @spec submit(String.t()) ::
          {:ok, String.t()} | {:error, :in_progress | :not_ready | {:invalid_path, String.t()}}
  def submit(path), do: GenServer.call(__MODULE__, {:submit, path})

  @doc "A job's record (`nil` id: the current or most recent job)."
  def status(nil), do: Repo.one(from(j in ImportJob, order_by: [desc: j.submitted_at], limit: 1))
  def status(id), do: Repo.get(ImportJob, id)

  # ------------------------------------------------------------- server

  @impl true
  def init(_) do
    # a job interrupted by a restart resumes on its own; a failed one waits for a re-submit
    case Repo.one(from(j in ImportJob, where: j.state == "running", limit: 1)) do
      nil -> {:ok, %{task: nil}}
      job -> {:ok, %{task: start(job)}}
    end
  end

  @impl true
  def handle_call({:submit, path}, _from, state) do
    cond do
      state.task != nil ->
        {:reply, {:error, :in_progress}, state}

      not Store.steady_state?() or Process.whereis(Writer) == nil ->
        {:reply, {:error, :not_ready}, state}

      true ->
        case resolve(path) do
          {:ok, full} ->
            id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

            job = %ImportJob{
              id: id,
              path: full,
              state: "running",
              phase: "parse_bucket",
              counters: %{},
              submitted_at: DateTime.utc_now()
            }

            {:ok, job} = Repo.insert(job)
            {:reply, {:ok, id}, %{state | task: start(job)}}

          {:error, msg} ->
            {:reply, {:error, {:invalid_path, msg}}, state}
        end
    end
  end

  @impl true
  def handle_info({ref, _}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | task: nil}}
  end

  def handle_info({:DOWN, ref, _, _, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.error("jetstream: import job crashed: #{inspect(reason)}")
    {:noreply, %{state | task: nil}}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp start(job),
    do: Task.Supervisor.async_nolink(Aerox.Jetstream.TaskSupervisor, fn -> run(job) end)

  # ------------------------------------------------------------ the job

  @doc false
  def run(%ImportJob{} = job) do
    job = if job.counters["bucketed"], do: job, else: parse(job)

    if job.state == "running" do
      :ok = Writer.rotate()
      apply_rules(job)
    else
      job
    end
  rescue
    e ->
      put_job(job, state: "failed", error: Exception.message(e), finished_at: DateTime.utc_now())
  end

  defp parse(job) do
    case parse_file(job.path) do
      {:ok, counters} ->
        put_job(job, phase: "apply", counters: Map.merge(counters, %{"bucketed" => true}))

      {:error, msg} ->
        put_job(job, state: "failed", error: msg, finished_at: DateTime.utc_now())
    end
  end

  @doc "Parses a CSV into rules; `{:ok, counters}` or `{:error, why the file failed}`."
  def parse_file(path) do
    stream = File.stream!(path, :line)

    Enum.reduce_while(
      Stream.with_index(stream),
      {:header, nil, %{"rowsTotal" => 0, "rowsValid" => 0, "rowsRejected" => 0}},
      fn {line, _n}, {stage, cols, c} ->
        line = String.trim_trailing(line, "\n") |> String.trim_trailing("\r")

        case {stage, split_csv(line)} do
          {_, {:error, msg}} ->
            {:halt, {:error, msg}}

          {:header, {:ok, names}} ->
            names = Enum.map(names, &String.trim/1)

            cond do
              Enum.any?(names, &(&1 not in @columns)) ->
                {:halt,
                 {:error,
                  "unrecognized column in header: #{Enum.find(names, &(&1 not in @columns))}"}}

              length(Enum.uniq(names)) != length(names) ->
                {:halt, {:error, "duplicate column in header"}}

              "uri" not in names or "timestamp" not in names ->
                {:halt, {:error, "header must name uri and timestamp"}}

              true ->
                {:cont, {:rows, names, c}}
            end

          {:rows, {:ok, [""]}} ->
            {:cont, {:rows, cols, c}}

          {:rows, {:ok, fields}} ->
            c = Map.update!(c, "rowsTotal", &(&1 + 1))

            case rule(Enum.zip(cols, fields) |> Map.new()) do
              {:ok, r} ->
                Repo.insert_all(TimestampRule, [r],
                  on_conflict: {:replace, [:indexed_at]},
                  conflict_target: [:uri, :cid]
                )

                {:cont, {:rows, cols, Map.update!(c, "rowsValid", &(&1 + 1))}}

              :error ->
                {:cont, {:rows, cols, Map.update!(c, "rowsRejected", &(&1 + 1))}}
            end
        end
      end
    )
    |> case do
      {:error, msg} -> {:error, msg}
      {:header, _, _} -> {:error, "empty file"}
      {:rows, _, c} -> {:ok, c}
    end
  end

  defp rule(%{"uri" => uri, "timestamp" => ts} = row) do
    scope = Map.get(row, "scope", "")
    cid = Map.get(row, "cid", "")

    with "at://" <> rest <- uri,
         [did, collection, rkey] <- String.split(rest, "/"),
         true <-
           Syntax.valid_did?(did) and Syntax.valid_nsid?(collection) and
             Syntax.valid_record_key?(rkey),
         {:ok, dt, _} <- DateTime.from_iso8601(ts),
         {:ok, cid} <-
           (case scope do
              s when s in ["", "all_versions"] -> {:ok, ""}
              "specific_version" when cid != "" -> {:ok, cid}
              _ -> :error
            end) do
      {:ok, %{uri: uri, cid: cid, indexed_at: DateTime.to_unix(dt, :microsecond)}}
    else
      _ -> :error
    end
  end

  defp rule(_), do: :error

  # RFC 4180 fields on one line; an unclosed or bare quote fails the file
  @doc false
  def split_csv(line), do: split_csv(line, [], "", false)

  defp split_csv("", acc, field, false), do: {:ok, Enum.reverse([field | acc])}
  defp split_csv("", _acc, _field, true), do: {:error, "unclosed quote"}

  defp split_csv(<<"\"\"", rest::binary>>, acc, field, true),
    do: split_csv(rest, acc, field <> "\"", true)

  defp split_csv(<<"\"", rest::binary>>, acc, field, true),
    do: split_csv(rest, acc, field, :closed)

  defp split_csv(<<",", rest::binary>>, acc, field, :closed),
    do: split_csv(rest, [field | acc], "", false)

  defp split_csv("", acc, field, :closed), do: {:ok, Enum.reverse([field | acc])}
  defp split_csv(_, _acc, _field, :closed), do: {:error, "bare quote"}
  defp split_csv(<<"\"", rest::binary>>, acc, "", false), do: split_csv(rest, acc, "", true)
  defp split_csv(<<"\"", _::binary>>, _acc, _field, false), do: {:error, "bare quote"}

  defp split_csv(<<",", rest::binary>>, acc, field, false),
    do: split_csv(rest, [field | acc], "", false)

  defp split_csv(<<c::utf8, rest::binary>>, acc, field, quoted),
    do: split_csv(rest, acc, field <> <<c::utf8>>, quoted)

  defp apply_rules(job) do
    rules = Repo.all(TimestampRule) |> Enum.group_by(& &1.uri)

    dids =
      rules
      |> Map.keys()
      |> Enum.map(&(&1 |> String.trim_leading("at://") |> String.split("/") |> hd()))
      |> Enum.uniq()

    done = MapSet.new(job.counters["appliedSegments"] || [])
    segments = Enum.reject(Manifest.sealed(), &MapSet.member?(done, &1.idx))
    job = put_job(job, counters: Map.merge(job.counters, %{"segmentsToApply" => length(segments)}))

    matched = :ets.new(:import_matched, [:set, :public])

    job =
      Enum.reduce(segments, job, fn seg, job ->
        c = job.counters
        c = Map.update(c, "segmentsExamined", 1, &(&1 + 1))

        c =
          if Enum.any?(dids, &Gloom.member?(seg.segment_bloom, &1)) do
            counts = :counters.new(3, [:write_concurrency])

            transform = fn e ->
              with true <- Event.materialization?(e),
                   [_ | _] = candidates <- rules["at://#{e.did}/#{e.collection}/#{e.rkey}"] do
                cid = Convert.cid(e.payload)

                case Enum.find(candidates, &(&1.cid == cid)) do
                  %{indexed_at: at} = r ->
                    :counters.add(counts, 2, 1)
                    :ets.insert(matched, {{r.uri, r.cid}})
                    %{e | indexed_at: at}

                  nil ->
                    case Enum.find(candidates, &(&1.cid == "")) do
                      %{indexed_at: at} ->
                        :counters.add(counts, 1, 1)
                        %{e | indexed_at: at}

                      nil ->
                        e
                    end
                end
              else
                _ -> e
              end
            end

            case Compactor.exclusive(fn ->
                   Compactor.rewrite(seg, fn _ -> true end, transform)
                 end) do
              {:ok, mutated} ->
                c
                |> Map.update("segmentsPatched", 1, &(&1 + 1))
                |> Map.update("rowsMutated", mutated, &(&1 + mutated))
                |> Map.update(
                  "rowsMatchedAllVersions",
                  :counters.get(counts, 1),
                  &(&1 + :counters.get(counts, 1))
                )
                |> Map.update(
                  "rowsMatchedSpecific",
                  :counters.get(counts, 2),
                  &(&1 + :counters.get(counts, 2))
                )

              :unchanged ->
                c
            end
          else
            c
          end

        c =
          c
          |> Map.update("segmentsApplied", 1, &(&1 + 1))
          |> Map.update("appliedSegments", [seg.idx], &[seg.idx | &1])

        put_job(job, counters: c)
      end)

    specific = from(r in TimestampRule, where: r.cid != "", select: {r.uri, r.cid}) |> Repo.all()
    unmatched = Enum.count(specific, &(:ets.lookup(matched, &1) == []))
    :ets.delete(matched)

    put_job(job,
      state: "complete",
      finished_at: DateTime.utc_now(),
      counters:
        Map.merge(job.counters, %{"specificCidsUnmatched" => unmatched, "rowsCorruptOffset" => 0})
    )
  end

  defp put_job(job, changes) do
    job |> Ecto.Changeset.change(changes) |> Repo.update!()
  end

  # confined to the import directory, symlinks included
  defp resolve(path) when is_binary(path) and path != "" do
    dir = realpath(Path.expand(Config.import_dir()))
    full = realpath(Path.expand(path, dir))

    cond do
      not (full == dir or String.starts_with?(full, dir <> "/")) ->
        {:error, "path escapes the import directory"}

      not File.exists?(full) ->
        {:error, "path not found"}

      not File.regular?(full) ->
        {:error, "path is not a file"}

      true ->
        {:ok, full}
    end
  end

  defp resolve(_), do: {:error, "path is required"}

  defp realpath(path) do
    path
    |> Path.split()
    |> Enum.reduce("/", fn part, acc ->
      next = Path.join(acc, part)

      case :file.read_link_all(next) do
        {:ok, target} -> realpath(Path.expand(to_string(target), acc))
        _ -> next
      end
    end)
  end
end
