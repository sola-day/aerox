defmodule Aerox.ImageServerCase do
  @moduledoc """
  Image CDN tests (DESIGN §16): starts the image server's supervisor when the
  application tree has not, points the cache at a throwaway directory that is
  emptied around every test, and offers libvips-made test images.
  """
  use Boundary, top_level?: true, deps: [Aerox.ATProto, Aerox.ImageServer]
  use ExUnit.CaseTemplate

  alias Vix.Vips.{Image, MutableImage, Operation}

  using do
    quote do
      import Aerox.ImageServerCase
    end
  end

  setup do
    ensure_started()
    Aerox.ImageServer.Cache.clear()
    on_exit(fn -> Aerox.ImageServer.Cache.clear() end)
    :ok
  end

  @doc "Starts `Aerox.ImageServer` under the test supervisor unless the app already runs it."
  def ensure_started do
    if Process.whereis(Aerox.ImageServer.Supervisor) == nil do
      ExUnit.Callbacks.start_supervised!(Aerox.ImageServer)
    end

    :ok
  end

  @doc "Overrides keys of an application env entry for the test, restoring it afterwards."
  def put_config(key, overrides) do
    previous = Application.get_env(:aerox, key, [])
    Application.put_env(:aerox, key, Keyword.merge(previous, overrides))
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:aerox, key, previous) end)
    :ok
  end

  @doc "A `w`×`h` RGB PNG."
  def png(w, h) do
    {:ok, img} = Operation.black(w, h, bands: 3)
    {:ok, bin} = Operation.pngsave_buffer(img)
    bin
  end

  @doc "A `w`×`h` JPEG carrying an EXIF orientation tag (1 = upright, 6 = rotate 90° CW)."
  def jpeg(w, h, orientation \\ 1) do
    {:ok, img} = Operation.black(w, h, bands: 3)

    {:ok, img} =
      Image.mutate(img, fn m -> :ok = MutableImage.set(m, "orientation", :gint, orientation) end)

    {:ok, bin} = Operation.jpegsave_buffer(img, Q: 90)
    bin
  end

  @doc "The CID (raw codec, sha-256) of some bytes, as a string."
  def cid_of(bytes), do: bytes |> Aerox.ATProto.CID.for_raw() |> Aerox.ATProto.CID.to_string()
end
