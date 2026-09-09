defmodule Aerox.Blob.MimeTest do
  use ExUnit.Case, async: true

  alias Aerox.Blob.Mime

  defp ftyp(brand), do: <<0, 0, 0, 0x18, "ftyp", brand::binary, 0, 0, 0, 0, "isomiso2">>
  defp riff(form), do: <<"RIFF", 0x24, 0, 0, 0, form::binary, "fmt ">>

  test "images" do
    assert {:ok, "image/jpeg"} = Mime.sniff(<<0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, "JFIF">>)

    assert {:ok, "image/png"} =
             Mime.sniff(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, "IHDR">>)

    assert {:ok, "image/gif"} = Mime.sniff("GIF87a\x01\x00\x01\x00")
    assert {:ok, "image/gif"} = Mime.sniff("GIF89a\x01\x00\x01\x00")
    assert {:ok, "image/webp"} = Mime.sniff(<<"RIFF", 0x1A, 0, 0, 0, "WEBPVP8 ">>)
    assert {:ok, "image/bmp"} = Mime.sniff(<<"BM", 0x3A, 0, 0, 0, 0, 0, 0, 0>>)
    assert {:ok, "image/tiff"} = Mime.sniff(<<"II", 0x2A, 0x00, 8, 0, 0, 0>>)
    assert {:ok, "image/tiff"} = Mime.sniff(<<"MM", 0x00, 0x2A, 0, 0, 0, 8>>)
    assert {:ok, "image/avif"} = Mime.sniff(ftyp("avif"))
    assert {:ok, "image/avif"} = Mime.sniff(ftyp("avis"))
    assert {:ok, "image/heic"} = Mime.sniff(ftyp("heic"))
    assert {:ok, "image/heic"} = Mime.sniff(ftyp("heix"))
    assert {:ok, "image/heif"} = Mime.sniff(ftyp("mif1"))
  end

  test "video" do
    assert {:ok, "video/mp4"} = Mime.sniff(ftyp("isom"))
    assert {:ok, "video/mp4"} = Mime.sniff(ftyp("mp42"))
    assert {:ok, "video/mp4"} = Mime.sniff(ftyp("mp41"))
    assert {:ok, "video/x-m4v"} = Mime.sniff(ftyp("M4V "))

    ebml = <<0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x86, 0x81, 0x01, 0x42, 0xF7, 0x81, 0x01>>
    assert {:ok, "video/webm"} = Mime.sniff(ebml <> <<0x42, 0x82, 0x84, "webm">>)
    assert {:ok, "video/x-matroska"} = Mime.sniff(ebml <> <<0x42, 0x82, 0x88, "matroska">>)
    assert {:ok, "video/x-matroska"} = Mime.sniff(ebml)
  end

  test "audio" do
    assert {:ok, "audio/mpeg"} = Mime.sniff(<<"ID3", 3, 0, 0, 0, 0, 0, 0>>)
    assert {:ok, "audio/mpeg"} = Mime.sniff(<<0xFF, 0xFB, 0x90, 0x00>>)
    assert {:ok, "audio/mpeg"} = Mime.sniff(<<0xFF, 0xF3, 0x90, 0x00>>)
    assert {:ok, "audio/mpeg"} = Mime.sniff(<<0xFF, 0xF2, 0x90, 0x00>>)
    assert {:ok, "audio/ogg"} = Mime.sniff(<<"OggS", 0, 2, 0, 0>>)
    assert {:ok, "audio/wav"} = Mime.sniff(riff("WAVE"))
    assert {:ok, "audio/flac"} = Mime.sniff(<<"fLaC", 0, 0, 0, 0x22>>)
  end

  test "documents and archives" do
    assert {:ok, "application/pdf"} = Mime.sniff("%PDF-1.7\n")
    assert {:ok, "application/gzip"} = Mime.sniff(<<0x1F, 0x8B, 0x08, 0>>)
    assert {:ok, "application/gzip"} = Mime.sniff(:zlib.gzip("x"))
    assert {:ok, "application/zip"} = Mime.sniff(<<"PK", 3, 4, 0x14, 0>>)
    assert {:ok, "application/zip"} = Mime.sniff(<<"PK", 5, 6, 0, 0>>)
    assert {:ok, "application/zip"} = Mime.sniff(<<"PK", 7, 8>>)
  end

  test "unknown" do
    assert :unknown = Mime.sniff("")
    assert :unknown = Mime.sniff("hello world")
    assert :unknown = Mime.sniff(<<0xFF, 0xD8>>)
    assert :unknown = Mime.sniff(<<"RIFF", 0, 0, 0, 0, "AVI ">>)
    assert :unknown = Mime.sniff(ftyp("qt  "))
    assert :unknown = Mime.sniff(<<"PK", 1, 2>>)
    assert :unknown = Mime.sniff(<<0xFF, 0xFA, 0, 0>>)
    assert :unknown = Mime.sniff("{\"json\": true}")
  end
end
