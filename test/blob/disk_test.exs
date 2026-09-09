defmodule Aerox.Blob.DiskTest do
  @moduledoc "The store contract against `Aerox.Blob.Disk`, plus its on-disk layout."
  use Aerox.Blob.StoreCase, async: true

  alias Aerox.ATProto.CID
  alias Aerox.Blob.Disk
  alias Aerox.Blob.Store

  @moduletag :tmp_dir

  setup %{tmp_dir: dir}, do: {:ok, store: {Disk, root: dir}}

  describe "Disk layout:" do
    test "permanent objects live at <root>/blobs/<did-safe>/<cid>", %{
      store: {_, root: root} = store
    } do
      did = "did:plc:layouttest"
      bytes = "layout"
      cid = CID.for_raw(bytes)

      assert :ok = Store.put_permanent(store, did, cid, bytes)

      path = Path.join([root, "blobs", "did_plc_layouttest", CID.to_string(cid)])
      assert File.read!(path) == bytes
      assert Disk.blob_path([root: root], did, cid) == path
      assert File.ls!(Path.join(root, "blobs")) == ["did_plc_layouttest"]
    end

    test "temp objects live under tmp/, quarantined under quarantine/", %{
      store: {_, root: root} = store
    } do
      did = "did:web:example.com"
      bytes = "roots"
      cid = CID.for_raw(bytes)

      assert {:ok, key} = Store.put_temp(store, did, bytes)
      assert File.read!(Path.join([root, "tmp", "did_web_example.com", key])) == bytes

      assert :ok = Store.make_permanent(store, did, key, cid)
      assert :ok = Store.quarantine(store, did, cid)

      assert File.read!(
               Path.join([root, "quarantine", "did_web_example.com", CID.to_string(cid)])
             ) == bytes

      refute File.exists?(Path.join([root, "blobs", "did_web_example.com", CID.to_string(cid)]))
    end

    test "directories are created 0700", %{store: {_, root: root} = store} do
      did = "did:plc:mode"
      assert :ok = Store.put_permanent(store, did, CID.for_raw("m"), "m")
      %File.Stat{mode: mode} = File.stat!(Path.join([root, "blobs", "did_plc_mode"]))
      assert Bitwise.band(mode, 0o777) == 0o700
    end

    test "a DID that is not a safe path component is rejected", %{store: store} do
      assert_raise ArgumentError, fn ->
        Store.has_stored?(store, "did:plc:../x", CID.for_raw("x"))
      end
    end

    test "presigned_url is unsupported", %{store: store} do
      assert :unsupported = Store.presigned_url(store, "did:plc:x", CID.for_raw("x"), 60)
    end
  end
end
