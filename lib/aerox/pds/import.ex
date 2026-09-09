defmodule Aerox.PDS.Import do
  @moduledoc """
  `com.atproto.repo.importRepo` (upstream `importRepo.ts`, DESIGN §8 item 4):
  a CAR is verified as a diff against the current repo (or as a full repo
  when the account is empty), its blocks stored, the root re-signed under a
  new rev, and every record indexed. Blobs the records reference become
  `record_blob` rows the account then fills through `uploadBlob`.
  """
  import Ecto.Query
  alias Aerox.ATProto.{CAR, CID, DagCBOR}
  alias Aerox.ATProto.Blockstore, as: KBlockstore
  alias Aerox.ATProto.Blockstore.Memory
  alias Aerox.ATProto.Repo, as: KRepo
  alias Aerox.PDS.{Accounts, Blockstore, Clock, Records, Repo}
  alias Aerox.PDS.Schema.{Backlink, Record, RecordBlob, RepoRoot}

  @spec import_car(String.t(), binary) :: :ok | {:error, term}
  def import_car(did, car) do
    with {:ok, root, blocks} <- CAR.decode_with_root(car) do
      staged = Memory.new(blocks)
      keypair = Accounts.signing_keypair(did) || {:error, :not_found}

      Repo.transaction(fn ->
        current = Repo.one(from(r in RepoRoot, where: r.did == ^did, lock: "FOR UPDATE"))
        base = Blockstore.new(did)

        prev =
          current &&
            (fn ->
               {:ok, repo} = KRepo.load(base, CID.parse!(current.cid))
               repo
             end).()

        rev = Clock.next_tid_after(current && current.rev)

        case KRepo.verify_diff(prev, staged, root, base: base, ensure_leaves: false) do
          {:error, reason} ->
            Repo.rollback("Could not verify repo: #{inspect(reason)}")

          {:ok, %{commit: commit, records: writes, new_blocks: new_blocks, diff: diff}} ->
            # re-sign under our rev so the sequencer's chain stays monotonic (upstream sets diff.commit.rev = rev)
            unsigned = commit |> Map.delete("sig") |> Map.put("rev", rev)
            signed = KRepo.sign_commit(unsigned, keypair)
            commit_bytes = DagCBOR.encode(signed)
            commit_cid = CID.for_cbor(commit_bytes)
            bs = Blockstore.new(did, rev)

            {:ok, _} =
              KBlockstore.put_many(bs, Map.to_list(Map.put(new_blocks, commit_cid, commit_bytes)))

            Blockstore.delete_many(
              did,
              MapSet.to_list(MapSet.delete(diff.removed_cids, commit_cid))
            )

            Repo.insert_all(
              RepoRoot,
              [
                %{
                  did: did,
                  cid: CID.to_string(commit_cid),
                  rev: rev,
                  indexed_at: DateTime.utc_now()
                }
              ],
              on_conflict: {:replace, [:cid, :rev, :indexed_at]},
              conflict_target: :did
            )

            now = DateTime.utc_now()

            for write <- writes do
              {:ok, collection, rkey} = KRepo.parse_data_key(write.path)
              uri = Aerox.ATProto.Syntax.at_uri(did, collection, rkey)

              case write.action do
                :delete ->
                  Repo.delete_all(from(r in Record, where: r.did == ^did and r.uri == ^uri))
                  Repo.delete_all(from(b in Backlink, where: b.did == ^did and b.uri == ^uri))

                _ ->
                  {:ok, bytes} =
                    KBlockstore.get(Aerox.ATProto.Blockstore.Layered.new(staged, base), write.cid)

                  record =
                    case Aerox.ATProto.Data.decode_cbor(bytes) do
                      {:ok, r} when is_map(r) -> r
                      _ -> Repo.rollback("Could not parse record at '#{write.path}'")
                    end

                  Repo.insert_all(
                    Record,
                    [
                      %{
                        did: did,
                        collection: collection,
                        rkey: rkey,
                        uri: uri,
                        cid: CID.to_string(write.cid),
                        rev: rev,
                        indexed_at: now
                      }
                    ],
                    on_conflict: {:replace, [:cid, :rev, :indexed_at]},
                    conflict_target: [:did, :collection, :rkey]
                  )

                  Repo.delete_all(from(b in Backlink, where: b.did == ^did and b.uri == ^uri))

                  links =
                    for {path, link_to} <- Records.backlinks(uri, record),
                        do: %{did: did, uri: uri, path: path, link_to: link_to}

                  if links != [], do: Repo.insert_all(Backlink, links, on_conflict: :nothing)

                  refs =
                    for %{"ref" => %CID{} = c} <- Aerox.ATProto.Data.blob_refs(record),
                        do: %{did: did, blob_cid: CID.to_string(c), record_uri: uri}

                  if refs != [], do: Repo.insert_all(RecordBlob, refs, on_conflict: :nothing)
              end
            end

            :ok
        end
      end)
      |> case do
        {:ok, :ok} -> :ok
        {:error, msg} -> {:error, msg}
      end
    end
  end
end
