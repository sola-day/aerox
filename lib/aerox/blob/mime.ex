defmodule Aerox.Blob.Mime do
  @moduledoc """
  Magic-byte MIME sniffing for uploaded blobs.

  Upstream's PDS runs `file-type` over the first bytes of an upload and stores
  the detected type when the client's `Content-Type` is missing or generic.
  `sniff/1` covers the image, video, audio and container formats a PDS sees;
  everything else is `:unknown`, and the caller falls back to the declared type.

  Only the first 64 bytes or so matter; passing more is fine, the whole blob
  is not needed.
  """

  @type mime :: String.t()

  @doc """
  Detects the MIME type from the leading bytes of a blob.

      iex> Aerox.Blob.Mime.sniff(<<0xFF, 0xD8, 0xFF, 0xE0>>)
      {:ok, "image/jpeg"}
      iex> Aerox.Blob.Mime.sniff("hello")
      :unknown
  """
  @spec sniff(binary) :: {:ok, mime} | :unknown
  # Images
  def sniff(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg"}
  def sniff(<<0x89, "PNG\r\n", 0x1A, "\n", _::binary>>), do: {:ok, "image/png"}
  def sniff(<<"GIF87a", _::binary>>), do: {:ok, "image/gif"}
  def sniff(<<"GIF89a", _::binary>>), do: {:ok, "image/gif"}
  def sniff(<<"RIFF", _::32, "WEBP", _::binary>>), do: {:ok, "image/webp"}
  def sniff(<<"BM", _::binary>>), do: {:ok, "image/bmp"}
  def sniff(<<"II", 0x2A, 0x00, _::binary>>), do: {:ok, "image/tiff"}
  def sniff(<<"MM", 0x00, 0x2A, _::binary>>), do: {:ok, "image/tiff"}

  # ISO base media file format: `<size:4> "ftyp" <major brand:4>`.
  def sniff(<<_::32, "ftyp", brand::binary-size(4), _::binary>>), do: ftyp(brand)

  # Video containers
  def sniff(<<0x1A, 0x45, 0xDF, 0xA3, _::binary>> = head), do: {:ok, matroska(head)}

  # Audio
  def sniff(<<"ID3", _::binary>>), do: {:ok, "audio/mpeg"}
  def sniff(<<0xFF, sync, _::binary>>) when sync in [0xFB, 0xF3, 0xF2], do: {:ok, "audio/mpeg"}
  def sniff(<<"OggS", _::binary>>), do: {:ok, "audio/ogg"}
  def sniff(<<"RIFF", _::32, "WAVE", _::binary>>), do: {:ok, "audio/wav"}
  def sniff(<<"fLaC", _::binary>>), do: {:ok, "audio/flac"}

  # Documents and archives
  def sniff(<<"%PDF", _::binary>>), do: {:ok, "application/pdf"}
  def sniff(<<0x1F, 0x8B, _::binary>>), do: {:ok, "application/gzip"}

  def sniff(<<"PK", a, b, _::binary>>) when {a, b} in [{3, 4}, {5, 6}, {7, 8}],
    do: {:ok, "application/zip"}

  def sniff(_), do: :unknown

  defp ftyp(brand) when brand in ["avif", "avis"], do: {:ok, "image/avif"}
  defp ftyp(brand) when brand in ["heic", "heix"], do: {:ok, "image/heic"}
  defp ftyp("mif1"), do: {:ok, "image/heif"}
  defp ftyp("M4V "), do: {:ok, "video/x-m4v"}
  defp ftyp(brand) when brand in ["isom", "iso2", "mp41", "mp42", "avc1"], do: {:ok, "video/mp4"}
  defp ftyp(_), do: :unknown

  # The EBML header carries a DocType element (id 0x4282, 1-byte size) naming
  # "webm" or "matroska"; anything without a webm DocType is Matroska.
  defp matroska(head) do
    case :binary.match(head, <<0x42, 0x82, 0x84, "webm">>) do
      {_, _} -> "video/webm"
      :nomatch -> "video/x-matroska"
    end
  end
end
