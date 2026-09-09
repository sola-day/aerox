defmodule Aerox.ImageServer.PresetsTest do
  @moduledoc "DESIGN §16: upstream's URL shape and presets, verbatim (`bsky/src/image/uri.ts`)."
  use ExUnit.Case, async: true

  alias Aerox.ImageServer.Presets

  @did "did:plc:ewvi7nxzyoun6zhxrhs64oiz"
  @cid "bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"

  test "the four presets carry upstream's dimensions, fit, min and default format" do
    assert Presets.names() == ~w(avatar banner feed_thumbnail feed_fullsize)

    assert {:ok, %{format: :webp, fit: :cover, width: 1000, height: 1000, min: true}} =
             Presets.fetch("avatar")

    assert {:ok, %{format: :webp, fit: :cover, width: 3000, height: 1000, min: true}} =
             Presets.fetch("banner")

    assert {:ok, %{format: :webp, fit: :inside, width: 2000, height: 2000, min: true}} =
             Presets.fetch("feed_thumbnail")

    assert {:ok, %{format: :webp, fit: :inside, width: 1000, height: 1000, min: true}} =
             Presets.fetch("feed_fullsize")

    assert Presets.fetch("thumbnail") == :error
  end

  test "parses /<preset>/plain/<did>/<cid>@<format>" do
    assert {:ok, opts} = Presets.parse_path("/avatar/plain/#{@did}/#{@cid}@jpeg")

    assert opts == %{
             preset: "avatar",
             did: @did,
             cid: @cid,
             format: :jpeg,
             fit: :cover,
             width: 1000,
             height: 1000,
             min: true
           }

    assert {:ok, %{format: :webp}} = Presets.parse_path("/avatar/plain/#{@did}/#{@cid}@webp")
  end

  test "the format suffix is optional and defaults per preset" do
    assert {:ok, %{preset: "feed_fullsize", format: :webp, cid: @cid}} =
             Presets.parse_path("/feed_fullsize/plain/#{@did}/#{@cid}")
  end

  test "rejects bad paths, presets and formats as upstream's getOptions" do
    assert Presets.parse_path("/avatar/#{@did}/#{@cid}") == {:error, :bad_path}
    assert Presets.parse_path("/") == {:error, :bad_path}
    assert Presets.parse_path("") == {:error, :bad_path}
    assert Presets.parse_path("/thumbnail/plain/#{@did}/#{@cid}") == {:error, :bad_preset}
    assert Presets.parse_path("/avatar/plain/#{@did}/#{@cid}@png") == {:error, :bad_format}
    # upstream's non-greedy regex folds a dangling "@" into the cid, which then
    # fails CID validation in the facade (400 either way)
    assert {:ok, %{cid: @cid <> "@", format: :webp}} =
             Presets.parse_path("/avatar/plain/#{@did}/#{@cid}@")
  end

  test "url/4 builds what upstream's getPresetUri emits (no format suffix)" do
    assert Presets.url("https://appview.test/img", "avatar", @did, @cid) ==
             "https://appview.test/img/avatar/plain/#{@did}/#{@cid}"

    assert Presets.url("https://appview.test/img/", "banner", @did, @cid) ==
             "https://appview.test/img/banner/plain/#{@did}/#{@cid}"

    assert_raise ArgumentError, fn -> Presets.url("https://x", "nope", @did, @cid) end
  end

  test "a built URL parses back to the same preset, did and cid" do
    "https://appview.test/img" <> path =
      Presets.url("https://appview.test/img", "feed_thumbnail", @did, @cid)

    assert {:ok, %{preset: "feed_thumbnail", did: @did, cid: @cid, format: :webp}} =
             Presets.parse_path(path)
  end

  test "content types and extensions" do
    assert Presets.content_type(:jpeg) == "image/jpeg"
    assert Presets.content_type(:webp) == "image/webp"
    assert Presets.extension(:jpeg) == "jpeg"
    assert Presets.parse_format("gif") == :error
  end
end
