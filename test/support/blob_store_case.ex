defmodule Aerox.Blob.StoreCase do
  @moduledoc """
  The `Aerox.Blob.Store` contract suite (DESIGN §4.4, VERIFICATION §4): every
  adapter runs the same tests. Using this template defines them all.

  The adapter under test is `{module, opts}`, found in this order:

    * `use Aerox.Blob.StoreCase, adapter: {Aerox.Blob.Disk, root: "/x"}` — static;
    * a `:store` key put into the test context by a `setup` in the using module
      (the way to get a fresh `tmp_dir` per test);
    * a `store/0` function defined by the using module.

  Each test uses fresh DIDs, so adapters with shared state (a bucket) stay
  independent across tests; `delete_all/2` runs for every DID afterwards.
  """
  use Boundary, top_level?: true, deps: [Aerox.Blob, Aerox.ATProto]
  use ExUnit.CaseTemplate

  alias Aerox.ATProto.CID
  alias Aerox.Blob.Store

  using opts do
    quote do
      import Aerox.Blob.StoreCase

      @doc false
      def __blob_store_adapter__, do: unquote(opts[:adapter])

      setup do
        {:ok, did: Aerox.Blob.StoreCase.fresh_did()}
      end

      describe "Aerox.Blob.Store contract:" do
        test "two-phase write: put_temp, make_permanent, get", context do
          %{store: store, did: did} = store_and_did(context)
          bytes = blob_bytes(1_000)
          cid = CID.for_raw(bytes)

          assert {:ok, key} = Store.put_temp(store, did, bytes)
          assert Store.has_temp?(store, did, key)
          refute Store.has_stored?(store, did, cid)
          assert {:error, :not_found} = Store.get(store, did, cid)

          assert :ok = Store.make_permanent(store, did, key, cid)
          assert Store.has_stored?(store, did, cid)
          refute Store.has_temp?(store, did, key)
          assert {:ok, ^bytes} = Store.get(store, did, cid)
        end

        test "put_temp accepts an iolist and a stream of chunks", context do
          %{store: store, did: did} = store_and_did(context)
          bytes = blob_bytes(300_000)
          cid = CID.for_raw(bytes)
          chunks = for <<chunk::binary-size(7_919) <- bytes>>, do: chunk

          tail =
            binary_part(
              bytes,
              byte_size(bytes) - rem(byte_size(bytes), 7_919),
              rem(byte_size(bytes), 7_919)
            )

          chunks = chunks ++ [tail]
          assert IO.iodata_to_binary(chunks) == bytes

          assert {:ok, key} = Store.put_temp(store, did, chunks)
          assert :ok = Store.make_permanent(store, did, key, cid)
          assert {:ok, ^bytes} = Store.get(store, did, cid)
          assert :ok = Store.delete(store, did, cid)

          assert {:ok, key} = Store.put_temp(store, did, Stream.map(chunks, & &1))
          assert :ok = Store.make_permanent(store, did, key, cid)
          assert {:ok, ^bytes} = Store.get(store, did, cid)
        end

        test "make_permanent is idempotent: an existing object wins, the temp is dropped",
             context do
          %{store: store, did: did} = store_and_did(context)
          bytes = blob_bytes(64)
          cid = CID.for_raw(bytes)

          assert {:ok, key1} = Store.put_temp(store, did, bytes)
          assert :ok = Store.make_permanent(store, did, key1, cid)
          assert {:ok, key2} = Store.put_temp(store, did, bytes)
          assert :ok = Store.make_permanent(store, did, key2, cid)

          refute Store.has_temp?(store, did, key2)
          assert {:ok, ^bytes} = Store.get(store, did, cid)
        end

        test "make_permanent of an unknown temp key is an error", context do
          %{store: store, did: did} = store_and_did(context)
          cid = CID.for_raw("nothing")
          assert {:error, _} = Store.make_permanent(store, did, "no-such-key", cid)
          refute Store.has_stored?(store, did, cid)
        end

        test "put_permanent stores and is idempotent", context do
          %{store: store, did: did} = store_and_did(context)
          bytes = blob_bytes(512)
          cid = CID.for_raw(bytes)

          assert :ok = Store.put_permanent(store, did, cid, bytes)
          assert {:ok, ^bytes} = Store.get(store, did, cid)
          assert :ok = Store.put_permanent(store, did, cid, bytes)
          assert :ok = Store.put_permanent(store, did, cid, Stream.map([bytes], & &1))
          assert {:ok, ^bytes} = Store.get(store, did, cid)
          assert Enum.to_list(Store.list(store, did)) == [cid]
        end

        test "delete is idempotent: a missing object is :ok", context do
          %{store: store, did: did} = store_and_did(context)
          bytes = blob_bytes(32)
          cid = CID.for_raw(bytes)

          assert :ok = Store.delete(store, did, cid)
          assert :ok = Store.put_permanent(store, did, cid, bytes)
          assert :ok = Store.delete(store, did, cid)
          refute Store.has_stored?(store, did, cid)
          assert {:error, :not_found} = Store.get(store, did, cid)
          assert :ok = Store.delete(store, did, cid)
        end

        test "stream returns the same bytes as get, in more than one chunk",
             context do
          %{store: store, did: did} = store_and_did(context)
          bytes = blob_bytes(250_000)
          cid = CID.for_raw(bytes)
          assert :ok = Store.put_permanent(store, did, cid, bytes)

          assert {:ok, stream} = Store.stream(store, did, cid)
          chunks = Enum.to_list(stream)
          assert length(chunks) > 1
          assert Enum.all?(chunks, &is_binary/1)
          assert IO.iodata_to_binary(chunks) == bytes
          assert {:ok, ^bytes} = Store.get(store, did, cid)

          assert {:error, :not_found} = Store.stream(store, did, CID.for_raw("absent"))
        end

        test "stream_temp serves the object until a record commits it", context do
          %{store: store, did: did} = store_and_did(context)
          bytes = blob_bytes(128)
          cid = CID.for_raw(bytes)

          assert {:ok, key} = Store.put_temp(store, did, bytes)
          assert {:ok, stream} = Store.stream_temp(store, did, key)
          assert IO.iodata_to_binary(Enum.to_list(stream)) == bytes
          assert {:error, :not_found} = Store.stream_temp(store, did, "no-such-key")

          assert :ok = Store.make_permanent(store, did, key, cid)
          assert {:error, :not_found} = Store.stream_temp(store, did, key)
          assert {:ok, ^bytes} = Store.get(store, did, cid)
        end

        test "quarantine hides an object; unquarantine restores it", context do
          %{store: store, did: did} = store_and_did(context)
          bytes = blob_bytes(128)
          cid = CID.for_raw(bytes)
          assert :ok = Store.put_permanent(store, did, cid, bytes)

          assert :ok = Store.quarantine(store, did, cid)
          refute Store.has_stored?(store, did, cid)
          assert {:error, :not_found} = Store.get(store, did, cid)
          assert {:error, :not_found} = Store.stream(store, did, cid)
          assert Enum.to_list(Store.list(store, did)) == []

          assert :ok = Store.unquarantine(store, did, cid)
          assert Store.has_stored?(store, did, cid)
          assert {:ok, ^bytes} = Store.get(store, did, cid)
          assert Enum.to_list(Store.list(store, did)) == [cid]

          assert {:error, _} = Store.quarantine(store, did, CID.for_raw("absent"))
          assert {:error, _} = Store.unquarantine(store, did, CID.for_raw("absent"))
        end

        test "list returns exactly the stored CIDs", context do
          %{store: store, did: did} = store_and_did(context)
          assert Enum.to_list(Store.list(store, did)) == []

          cids =
            for i <- 1..5 do
              bytes = blob_bytes(100 + i)
              cid = CID.for_raw(bytes)
              assert :ok = Store.put_permanent(store, did, cid, bytes)
              cid
            end

          # A temp object is not listed.
          assert {:ok, _key} = Store.put_temp(store, did, "temp only")

          assert Enum.sort(Store.list(store, did)) == Enum.sort(cids)
          assert Enum.all?(Store.list(store, did), &match?(%CID{codec: :raw}, &1))
        end

        test "delete_many removes the given objects and tolerates missing ones",
             context do
          %{store: store, did: did} = store_and_did(context)
          [b1, b2, b3] = for i <- 1..3, do: blob_bytes(40 + i)
          [c1, c2, c3] = Enum.map([b1, b2, b3], &CID.for_raw/1)

          for {c, b} <- [{c1, b1}, {c2, b2}, {c3, b3}],
              do: assert(:ok = Store.put_permanent(store, did, c, b))

          assert :ok = Store.delete_many(store, did, [c1, c2, CID.for_raw("absent")])
          refute Store.has_stored?(store, did, c1)
          refute Store.has_stored?(store, did, c2)
          assert Store.has_stored?(store, did, c3)
          assert Enum.to_list(Store.list(store, did)) == [c3]
          assert :ok = Store.delete_many(store, did, [])
        end

        test "delete_all empties one DID and leaves another alone", context do
          %{store: store, did: did} = store_and_did(context)
          other = fresh_did()
          bytes = blob_bytes(77)
          cid = CID.for_raw(bytes)
          quarantined = blob_bytes(78)
          qcid = CID.for_raw(quarantined)

          assert :ok = Store.put_permanent(store, did, cid, bytes)
          assert :ok = Store.put_permanent(store, did, qcid, quarantined)
          assert :ok = Store.quarantine(store, did, qcid)
          assert {:ok, key} = Store.put_temp(store, did, "temp")
          assert :ok = Store.put_permanent(store, other, cid, bytes)

          assert :ok = Store.delete_all(store, did)
          refute Store.has_stored?(store, did, cid)
          refute Store.has_temp?(store, did, key)
          assert {:error, _} = Store.unquarantine(store, did, qcid)
          assert Enum.to_list(Store.list(store, did)) == []

          assert Store.has_stored?(store, other, cid)
          assert {:ok, ^bytes} = Store.get(store, other, cid)
          assert Enum.to_list(Store.list(store, other)) == [cid]

          # A second delete_all, and one for a DID that never stored anything, are :ok.
          assert :ok = Store.delete_all(store, did)
          assert :ok = Store.delete_all(store, fresh_did())
          assert :ok = Store.delete_all(store, other)
        end

        test "the same CID under two DIDs is two independent objects", context do
          %{store: store, did: did} = store_and_did(context)
          other = fresh_did()
          bytes = blob_bytes(90)
          cid = CID.for_raw(bytes)

          assert :ok = Store.put_permanent(store, did, cid, bytes)
          refute Store.has_stored?(store, other, cid)
          assert {:error, :not_found} = Store.get(store, other, cid)
          assert Enum.to_list(Store.list(store, other)) == []

          assert :ok = Store.put_permanent(store, other, cid, bytes)
          assert :ok = Store.quarantine(store, did, cid)
          assert Store.has_stored?(store, other, cid)

          assert :ok = Store.unquarantine(store, did, cid)
          assert :ok = Store.delete(store, other, cid)
          assert Store.has_stored?(store, did, cid)
          assert {:ok, ^bytes} = Store.get(store, did, cid)

          assert :ok = Store.delete_all(store, other)
        end

        test "presigned_url answers :unsupported or a URL", context do
          %{store: store, did: did} = store_and_did(context)
          bytes = blob_bytes(10)
          cid = CID.for_raw(bytes)
          assert :ok = Store.put_permanent(store, did, cid, bytes)

          case Store.presigned_url(store, did, cid, 60) do
            :unsupported -> :ok
            {:ok, url} -> assert is_binary(url) and url != ""
          end
        end
      end
    end
  end

  @doc false
  # Resolved per test, after every `setup` in the using module has run.
  def store_and_did(%{module: module, did: did} = context) do
    store =
      cond do
        store = context[:store] -> store
        store = module.__blob_store_adapter__() -> store
        function_exported?(module, :store, 0) -> module.store()
        true -> raise "#{inspect(module)}: no blob store adapter given"
      end

    %{store: store, did: did}
  end

  @doc "A unique `did:plc:` for one test, so tests never share objects."
  @spec fresh_did() :: String.t()
  def fresh_did do
    suffix = 12 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false)
    "did:plc:" <> String.slice(suffix, 0, 24)
  end

  @doc "`n` bytes of deterministic-but-unique content (random prefix, patterned body)."
  @spec blob_bytes(non_neg_integer) :: binary
  def blob_bytes(n) do
    prefix = :crypto.strong_rand_bytes(min(n, 16))
    body = :binary.copy(<<0::8, 1::8, 2::8, 3::8, 255::8>>, div(n, 5) + 1)
    binary_part(prefix <> body, 0, n)
  end
end
