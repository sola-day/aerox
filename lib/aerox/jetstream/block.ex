defmodule Aerox.Jetstream.Block do
  @moduledoc """
  A Jetstream segment block (docs/README.md §3.2): the rows of up to one block,
  column by column, compressed as a single zstd frame with a content checksum.

      event_count u32
      seq[] u64 · witnessed_at[] i64 · indexed_at[] i64 · kind[] u8
      collection_len[] u8 · did_len[] u16 · rkey_len[] u8 · rev_len[] u8 · payload_len[] u32
      collections · dids · rkeys · revs · payloads

  All integers little-endian. This is the frame `getBlock` serves verbatim.
  """
  alias Aerox.Jetstream.Event

  # decodeBlock's sanity bound on event_count
  @max_events 262_144

  @doc "The uncompressed column layout."
  @spec encode([Event.t()]) :: binary
  def encode(events) do
    n = length(events)

    IO.iodata_to_binary([
      <<n::little-32>>,
      Enum.map(events, &<<&1.seq::little-64>>),
      Enum.map(events, &<<&1.witnessed_at::little-signed-64>>),
      Enum.map(events, &<<&1.indexed_at::little-signed-64>>),
      Enum.map(events, &<<Event.kind_code(&1.kind)>>),
      Enum.map(events, &<<byte_size(&1.collection)>>),
      Enum.map(events, &<<byte_size(&1.did)::little-16>>),
      Enum.map(events, &<<byte_size(&1.rkey)>>),
      Enum.map(events, &<<byte_size(&1.rev)>>),
      Enum.map(events, &<<byte_size(&1.payload)::little-32>>),
      Enum.map(events, & &1.collection),
      Enum.map(events, & &1.did),
      Enum.map(events, & &1.rkey),
      Enum.map(events, & &1.rev),
      Enum.map(events, & &1.payload)
    ])
  end

  @doc "Rows that cannot be represented in the column widths are refused (`ErrFieldTooLong`)."
  @spec validate(Event.t()) :: :ok | {:error, term}
  def validate(%Event{} = e) do
    cond do
      byte_size(e.did) > 0xFFFF -> {:error, {:field_too_long, :did}}
      byte_size(e.collection) > 0xFF -> {:error, {:field_too_long, :collection}}
      byte_size(e.rkey) > 0xFF -> {:error, {:field_too_long, :rkey}}
      byte_size(e.rev) > 0xFF -> {:error, {:field_too_long, :rev}}
      byte_size(e.payload) > 0xFFFFFFFF -> {:error, {:field_too_long, :payload}}
      true -> :ok
    end
  end

  @doc "Encodes and compresses; returns `{frame, uncompressed_size}`."
  @spec compress([Event.t()]) :: {binary, non_neg_integer}
  def compress(events) do
    body = encode(events)
    {zstd(body), byte_size(body)}
  end

  @doc "A zstd frame with a content checksum (the segment format's compressor settings)."
  def zstd(body) do
    body |> :zstd.compress(%{checksumFlag: true, compressionLevel: 3}) |> IO.iodata_to_binary()
  end

  @doc "Decompresses and decodes a frame."
  @spec decompress(binary) :: {:ok, [Event.t()], non_neg_integer} | {:error, term}
  def decompress(frame) do
    body = frame |> :zstd.decompress() |> IO.iodata_to_binary()

    with {:ok, events} <- decode(body), do: {:ok, events, byte_size(body)}
  rescue
    e -> {:error, {:zstd, e}}
  end

  @doc "Decodes the uncompressed column layout."
  @spec decode(binary) :: {:ok, [Event.t()]} | {:error, :truncated_block}
  def decode(<<n::little-32, rest::binary>>) when n <= @max_events do
    fixed = n * 33

    with <<seqs::binary-size(^n * 8), wits::binary-size(^n * 8), idxs::binary-size(^n * 8),
           kinds::binary-size(^n), clens::binary-size(^n), dlens::binary-size(^n * 2),
           rlens::binary-size(^n), vlens::binary-size(^n), plens::binary-size(^n * 4),
           var::binary>> <- rest,
         true <- byte_size(rest) >= fixed,
         clens = for(<<l <- clens>>, do: l),
         dlens = for(<<l::little-16 <- dlens>>, do: l),
         rlens = for(<<l <- rlens>>, do: l),
         vlens = for(<<l <- vlens>>, do: l),
         plens = for(<<l::little-32 <- plens>>, do: l),
         {:ok, collections, var} <- take(var, clens),
         {:ok, dids, var} <- take(var, dlens),
         {:ok, rkeys, var} <- take(var, rlens),
         {:ok, revs, var} <- take(var, vlens),
         {:ok, payloads, <<>>} <- take(var, plens),
         {:ok, kinds} <- kinds(kinds) do
      events =
        [
          for(<<s::little-64 <- seqs>>, do: s),
          for(<<w::little-signed-64 <- wits>>, do: w),
          for(<<i::little-signed-64 <- idxs>>, do: i),
          kinds,
          collections,
          dids,
          rkeys,
          revs,
          payloads
        ]
        |> Enum.zip()
        |> Enum.map(fn {s, w, i, k, c, d, r, v, p} ->
          %Event{
            seq: s,
            witnessed_at: w,
            indexed_at: i,
            kind: k,
            collection: c,
            did: d,
            rkey: r,
            rev: v,
            payload: p
          }
        end)

      {:ok, events}
    else
      _ -> {:error, :truncated_block}
    end
  end

  def decode(_), do: {:error, :truncated_block}

  defp take(bin, lens) do
    Enum.reduce_while(lens, {:ok, [], bin}, fn l, {:ok, acc, rest} ->
      case rest do
        <<v::binary-size(^l), rest::binary>> -> {:cont, {:ok, [v | acc], rest}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc, rest} -> {:ok, Enum.reverse(acc), rest}
      :error -> :error
    end
  end

  defp kinds(bin) do
    Enum.reduce_while(for(<<k <- bin>>, do: k), {:ok, []}, fn code, {:ok, acc} ->
      case Event.kind_from_code(code) do
        {:ok, kind} -> {:cont, {:ok, [kind | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end
end
