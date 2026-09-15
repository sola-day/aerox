defmodule Aerox.Jetstream.XXH3 do
  @moduledoc """
  XXH3, 64- and 128-bit, unseeded — transcribed from `github.com/zeebo/xxh3`
  v1.1.0 (the scalar path), which Jetstream's segment format depends on twice:
  the segment checksum is XXH3-64 over the header and footer, and gloom bloom
  filters place DIDs with XXH3-128. Checked against that package's 4096-length
  C-compat vectors (`test/golden/jetstream/xxh3-vectors.json`).

  Pure Elixir with explicit 64-bit wrapping; fast enough for the short inputs it
  sees (DIDs, segment footers).
  """
  import Bitwise

  @m64 0xFFFFFFFFFFFFFFFF
  @m32 0xFFFFFFFF

  @p32_1 2_654_435_761
  @p32_2 2_246_822_519
  @p32_3 3_266_489_917
  @p64_1 11_400_714_785_074_694_791
  @p64_2 14_029_467_366_897_019_727
  @p64_3 1_609_587_929_392_839_161
  @p64_4 9_650_029_242_287_828_579
  @p64_5 2_870_177_450_012_600_261

  @key <<0xB8, 0xFE, 0x6C, 0x39, 0x23, 0xA4, 0x4B, 0xBE, 0x7C, 0x01, 0x81, 0x2C, 0xF7, 0x21, 0xAD,
         0x1C, 0xDE, 0xD4, 0x6D, 0xE9, 0x83, 0x90, 0x97, 0xDB, 0x72, 0x40, 0xA4, 0xA4, 0xB7, 0xB3,
         0x67, 0x1F, 0xCB, 0x79, 0xE6, 0x4E, 0xCC, 0xC0, 0xE5, 0x78, 0x82, 0x5A, 0xD0, 0x7D, 0xCC,
         0xFF, 0x72, 0x21, 0xB8, 0x08, 0x46, 0x74, 0xF7, 0x43, 0x24, 0x8E, 0xE0, 0x35, 0x90, 0xE6,
         0x81, 0x3A, 0x26, 0x4C, 0x3C, 0x28, 0x52, 0xBB, 0x91, 0xC3, 0x00, 0xCB, 0x88, 0xD0, 0x65,
         0x8B, 0x1B, 0x53, 0x2E, 0xA3, 0x71, 0x64, 0x48, 0x97, 0xA2, 0x0D, 0xF9, 0x4E, 0x38, 0x19,
         0xEF, 0x46, 0xA9, 0xDE, 0xAC, 0xD8, 0xA8, 0xFA, 0x76, 0x3F, 0xE3, 0x9C, 0x34, 0x3F, 0xF9,
         0xDC, 0xBB, 0xC7, 0xC7, 0x0B, 0x4F, 0x1D, 0x8A, 0x51, 0xE0, 0x4B, 0xCD, 0xB4, 0x59, 0x31,
         0xC8, 0x9F, 0x7E, 0xC9, 0xD9, 0x78, 0x73, 0x64, 0xEA, 0xC5, 0xAC, 0x83, 0x34, 0xD3, 0xEB,
         0xC3, 0xC5, 0x81, 0xA0, 0xFF, 0xFA, 0x13, 0x63, 0xEB, 0x17, 0x0D, 0xDD, 0x51, 0xB7, 0xF0,
         0xDA, 0x49, 0xD3, 0x16, 0x55, 0x26, 0x29, 0xD4, 0x68, 0x9E, 0x2B, 0x16, 0xBE, 0x58, 0x7D,
         0x47, 0xA1, 0xFC, 0x8F, 0xF8, 0xB8, 0xD1, 0x7A, 0xD0, 0x31, 0xCE, 0x45, 0xCB, 0x3A, 0x8F,
         0x95, 0x16, 0x04, 0x28, 0xAF, 0xD7, 0xFB, 0xCA, 0xBB, 0x4B, 0x40, 0x7E>>

  # the secret's little-endian 64-bit words at every offset the algorithm reads
  for off <- 0..184 do
    <<_::binary-size(^off), v::little-64, _::binary>> = @key
    defp k64(unquote(off)), do: unquote(v)
  end

  for off <- [0, 4, 8, 12] do
    <<_::binary-size(^off), v::little-32, _::binary>> = @key
    defp k32(unquote(off)), do: unquote(v)
  end

  # ------------------------------------------------------------ 64-bit

  @doc "XXH3-64 of `data`."
  @spec hash64(binary) :: non_neg_integer
  def hash64(data) when is_binary(data), do: hash64(data, byte_size(data))

  defp hash64(_d, 0), do: 0x2D06800538D394C2

  defp hash64(d, l) when l <= 3 do
    d |> small_acc(l) |> bxor(bxor(k32(0), k32(4))) |> avalanche_xxh(:small)
  end

  defp hash64(d, l) when l <= 8 do
    input1 = u32(d, 0)
    input2 = u32(d, l - 4)
    keyed = bxor(input2 + (input1 <<< 32), bxor(k64(8), k64(16)))
    rrmxmx(keyed, l)
  end

  defp hash64(d, l) when l <= 16 do
    lo = bxor(u64(d, 0), bxor(k64(24), k64(32)))
    hi = bxor(u64(d, l - 8), bxor(k64(40), k64(48)))
    avalanche3(wrap(l + bswap64(lo) + hi + mulfold(lo, hi)))
  end

  defp hash64(d, l) when l <= 128 do
    acc = wrap(l * @p64_1)

    acc =
      if l > 32 do
        acc =
          if l > 64 do
            acc =
              if l > 96 do
                acc
                |> add(mulfold(bxor(u64(d, 48), k64(96)), bxor(u64(d, 56), k64(104))))
                |> add(mulfold(bxor(u64(d, l - 64), k64(112)), bxor(u64(d, l - 56), k64(120))))
              else
                acc
              end

            acc
            |> add(mulfold(bxor(u64(d, 32), k64(64)), bxor(u64(d, 40), k64(72))))
            |> add(mulfold(bxor(u64(d, l - 48), k64(80)), bxor(u64(d, l - 40), k64(88))))
          else
            acc
          end

        acc
        |> add(mulfold(bxor(u64(d, 16), k64(32)), bxor(u64(d, 24), k64(40))))
        |> add(mulfold(bxor(u64(d, l - 32), k64(48)), bxor(u64(d, l - 24), k64(56))))
      else
        acc
      end

    acc
    |> add(mulfold(bxor(u64(d, 0), k64(0)), bxor(u64(d, 8), k64(8))))
    |> add(mulfold(bxor(u64(d, l - 16), k64(16)), bxor(u64(d, l - 8), k64(24))))
    |> avalanche3()
  end

  defp hash64(d, l) when l <= 240 do
    acc =
      Enum.reduce(0..7, wrap(l * @p64_1), fn i, acc ->
        add(
          acc,
          mulfold(bxor(u64(d, 16 * i), k64(16 * i)), bxor(u64(d, 16 * i + 8), k64(16 * i + 8)))
        )
      end)
      |> avalanche3()

    top = l &&& bnot(15)

    acc =
      Stream.iterate(128, &(&1 + 16))
      |> Enum.take_while(&(&1 < top))
      |> Enum.reduce(acc, fn i, acc ->
        add(acc, mulfold(bxor(u64(d, i), k64(i - 125)), bxor(u64(d, i + 8), k64(i - 117))))
      end)

    acc
    |> add(mulfold(bxor(u64(d, l - 16), k64(119)), bxor(u64(d, l - 8), k64(127))))
    |> avalanche3()
  end

  defp hash64(d, l) do
    accs = accumulate_long(d, l)
    acc = wrap(l * @p64_1)

    acc
    |> add(mulfold(bxor(elem(accs, 0), k64(11)), bxor(elem(accs, 1), k64(19))))
    |> add(mulfold(bxor(elem(accs, 2), k64(27)), bxor(elem(accs, 3), k64(35))))
    |> add(mulfold(bxor(elem(accs, 4), k64(43)), bxor(elem(accs, 5), k64(51))))
    |> add(mulfold(bxor(elem(accs, 6), k64(59)), bxor(elem(accs, 7), k64(67))))
    |> avalanche3()
  end

  # ----------------------------------------------------------- 128-bit

  @doc "XXH3-128 of `data` as `{hi, lo}`."
  @spec hash128(binary) :: {non_neg_integer, non_neg_integer}
  def hash128(data) when is_binary(data), do: hash128(data, byte_size(data))

  defp hash128(_d, 0), do: {0x99AA06D3014798D8, 0x6001C324468D497F}

  defp hash128(d, l) when l <= 3 do
    lo = small_acc(d, l)
    hi = lo |> band(@m32) |> bswap32() |> rotl32(13)
    lo = bxor(lo, bxor(k32(0), k32(4)))
    hi = bxor(hi, bxor(k32(8), k32(12)))
    {avalanche_xxh64_small(hi), avalanche_xxh64_small(lo)}
  end

  defp hash128(d, l) when l <= 8 do
    input_lo = u32(d, 0)
    input_hi = u32(d, l - 4)
    keyed = bxor(input_lo + (input_hi <<< 32), bxor(k64(16), k64(24)))
    {hi, lo} = mul128(keyed, wrap(@p64_1 + (l <<< 2)))
    hi = wrap(hi + (lo <<< 1))
    lo = bxor(lo, hi >>> 3)
    lo = bxor(lo, lo >>> 35)
    lo = wrap(lo * 0x9FB21C651E98DF25)
    lo = bxor(lo, lo >>> 28)
    {avalanche3(hi), lo}
  end

  defp hash128(d, l) when l <= 16 do
    input_lo = u64(d, 0)
    input_hi = u64(d, l - 8)
    {m_h, m_l} = mul128(bxor(bxor(input_lo, input_hi), bxor(k64(32), k64(40))), @p64_1)
    m_l = wrap(m_l + ((l - 1) <<< 54))
    input_hi = bxor(input_hi, bxor(k64(48), k64(56)))
    m_h = wrap(m_h + input_hi + (input_hi &&& @m32) * (@p32_2 - 1))
    m_l = bxor(m_l, bswap64(m_h))
    {hi, lo} = mul128(m_l, @p64_2)
    hi = wrap(hi + m_h * @p64_2)
    {avalanche3(hi), avalanche3(lo)}
  end

  defp hash128(d, l) when l <= 128 do
    acc = {0, wrap(l * @p64_1)}

    acc =
      if l > 32 do
        acc =
          if l > 64 do
            acc = if l > 96, do: mix32(acc, d, l, 48, l - 64, 96, 112), else: acc
            mix32(acc, d, l, 32, l - 48, 64, 80)
          else
            acc
          end

        mix32(acc, d, l, 16, l - 32, 32, 48)
      else
        acc
      end

    acc |> mix32(d, l, 0, l - 16, 0, 16) |> finish128(l)
  end

  defp hash128(d, l) when l <= 240 do
    acc =
      Enum.reduce(0..3, {0, wrap(l * @p64_1)}, fn i, acc ->
        mix_quad(
          acc,
          u64(d, i * 32),
          u64(d, i * 32 + 8),
          u64(d, i * 32 + 16),
          u64(d, i * 32 + 24),
          k64(i * 32),
          k64(i * 32 + 8),
          k64(i * 32 + 16),
          k64(i * 32 + 24)
        )
      end)

    {hi, lo} = acc
    acc = {avalanche3(hi), avalanche3(lo)}
    top = l &&& bnot(31)

    acc =
      Stream.iterate(128, &(&1 + 32))
      |> Enum.take_while(&(&1 < top))
      |> Enum.reduce(acc, fn i, acc ->
        mix_quad(
          acc,
          u64(d, i),
          u64(d, i + 8),
          u64(d, i + 16),
          u64(d, i + 24),
          k64(i - 125),
          k64(i - 117),
          k64(i - 109),
          k64(i - 101)
        )
      end)

    # the last 32 bytes, with the roles of the pairs swapped
    {hi, lo} = acc
    i0 = u64(d, l - 32)
    i1 = u64(d, l - 24)
    i2 = u64(d, l - 16)
    i3 = u64(d, l - 8)
    hi = bxor(add(hi, mulfold(bxor(i0, k64(119)), bxor(i1, k64(127)))), wrap(i2 + i3))
    lo = bxor(add(lo, mulfold(bxor(i2, k64(103)), bxor(i3, k64(111)))), wrap(i0 + i1))
    finish128({hi, lo}, l)
  end

  defp hash128(d, l) do
    accs = accumulate_long(d, l)
    lo = wrap(l * @p64_1)
    hi = band(bnot(wrap(l * @p64_2)), @m64)

    {hi, lo} =
      Enum.reduce(
        [
          {0, 11, 19, 117, 125},
          {2, 27, 35, 133, 141},
          {4, 43, 51, 149, 157},
          {6, 59, 67, 165, 173}
        ],
        {hi, lo},
        fn {i, ka, kb, kc, kd}, {hi, lo} ->
          a = elem(accs, i)
          b = elem(accs, i + 1)

          {add(hi, mulfold(bxor(a, k64(kc)), bxor(b, k64(kd)))),
           add(lo, mulfold(bxor(a, k64(ka)), bxor(b, k64(kb))))}
        end
      )

    {avalanche3(hi), avalanche3(lo)}
  end

  # acc.Hi += mulfold(in_a ^ k_hi_a, in_b ^ k_hi_b); acc.Hi ^= i_a + i_b;
  # acc.Lo += mulfold(i_a ^ k_lo_a, i_b ^ k_lo_b); acc.Lo ^= in_a + in_b
  defp mix32({hi, lo}, d, _l, front, back, klo, khi) do
    i_a = u64(d, front)
    i_b = u64(d, front + 8)
    in_a = u64(d, back)
    in_b = u64(d, back + 8)
    hi = bxor(add(hi, mulfold(bxor(in_a, k64(khi)), bxor(in_b, k64(khi + 8)))), wrap(i_a + i_b))
    lo = bxor(add(lo, mulfold(bxor(i_a, k64(klo)), bxor(i_b, k64(klo + 8)))), wrap(in_a + in_b))
    {hi, lo}
  end

  defp mix_quad({hi, lo}, i0, i1, i2, i3, k0, k1, k2, k3) do
    hi = bxor(add(hi, mulfold(bxor(i2, k2), bxor(i3, k3))), wrap(i0 + i1))
    lo = bxor(add(lo, mulfold(bxor(i0, k0), bxor(i1, k1))), wrap(i2 + i3))
    {hi, lo}
  end

  defp finish128({hi, lo}, l) do
    new_hi = wrap(lo * @p64_1 + hi * @p64_4 + l * @p64_2)
    new_lo = wrap(hi + lo)
    {band(-avalanche3(new_hi), @m64), avalanche3(new_lo)}
  end

  # -------------------------------------------------------- long inputs

  defp accumulate_long(d, l) do
    accs = {@p32_3, @p64_1, @p64_2, @p64_3, @p64_4, @p32_2, @p64_5, @p32_1}
    {accs, pos, l} = blocks(d, accs, 0, l)

    # l > 0 here: the block loop runs only while more than a block remains
    t = div(l - 1, 64)

    accs =
      Enum.reduce(0..(t - 1)//1, accs, fn i, accs -> stripe(accs, d, pos + i * 64, i * 8) end)

    pos = pos + t * 64
    rest = l - t * 64

    if rest > 0, do: stripe(accs, d, pos + rest - 64, 121), else: accs
  end

  defp blocks(d, accs, pos, l) when l > 1024 do
    accs = Enum.reduce(0..15, accs, fn i, accs -> stripe(accs, d, pos + i * 64, i * 8) end)
    blocks(d, scramble(accs), pos + 1024, l - 1024)
  end

  defp blocks(_d, accs, pos, l), do: {accs, pos, l}

  defp stripe(accs, d, pos, koff) do
    Enum.reduce(0..7, accs, fn i, accs ->
      dv = u64(d, pos + 8 * i)
      dk = bxor(dv, k64(koff + 8 * i))
      mate = bxor(i, 1)
      accs = put_elem(accs, mate, wrap(elem(accs, mate) + dv))
      put_elem(accs, i, wrap(elem(accs, i) + (dk &&& @m32) * (dk >>> 32)))
    end)
  end

  defp scramble(accs) do
    Enum.reduce(0..7, accs, fn i, accs ->
      a = elem(accs, i)
      a = bxor(bxor(a, a >>> 47), k64(128 + 8 * i))
      put_elem(accs, i, wrap(a * @p32_1))
    end)
  end

  # ------------------------------------------------------------ helpers

  defp small_acc(d, 3), do: (u16(d, 0) <<< 16) + :binary.at(d, 2) + (3 <<< 8)
  defp small_acc(d, 2), do: ((u16(d, 0) * ((1 <<< 24) + 1)) >>> 8) + (2 <<< 8)
  defp small_acc(d, 1), do: :binary.at(d, 0) * ((1 <<< 24) + (1 <<< 16) + 1) + (1 <<< 8)

  defp avalanche_xxh(x, :small) do
    x = bxor(x, x >>> 33)
    x = wrap(x * @p64_2)
    x = bxor(x, x >>> 29)
    x = wrap(x * @p64_3)
    bxor(x, x >>> 32)
  end

  defp avalanche_xxh64_small(x) do
    x = wrap(x * @p64_2)
    x = bxor(x, x >>> 29)
    x = wrap(x * @p64_3)
    bxor(x, x >>> 32)
  end

  defp avalanche3(x) do
    x = bxor(x, x >>> 37)
    x = wrap(x * 0x165667919E3779F9)
    bxor(x, x >>> 32)
  end

  defp rrmxmx(h, l) do
    h = bxor(h, bxor(rotl64(h, 49), rotl64(h, 24)))
    h = wrap(h * 0x9FB21C651E98DF25)
    h = bxor(h, (h >>> 35) + l)
    h = wrap(h * 0x9FB21C651E98DF25)
    bxor(h, h >>> 28)
  end

  defp mulfold(a, b) do
    p = a * b
    bxor(p >>> 64, p &&& @m64)
  end

  defp mul128(a, b) do
    p = a * b
    {p >>> 64, p &&& @m64}
  end

  defp add(a, b), do: wrap(a + b)
  defp wrap(x), do: x &&& @m64

  defp rotl64(x, r), do: (x <<< r ||| x >>> (64 - r)) &&& @m64
  defp rotl32(x, r), do: (x <<< r ||| x >>> (32 - r)) &&& @m32

  defp bswap64(x) do
    <<v::little-64>> = <<x::big-64>>
    v
  end

  defp bswap32(x) do
    <<v::little-32>> = <<x::big-32>>
    v
  end

  defp u64(d, off) do
    <<_::binary-size(^off), v::little-64, _::binary>> = d
    v
  end

  defp u32(d, off) do
    <<_::binary-size(^off), v::little-32, _::binary>> = d
    v
  end

  defp u16(d, off) do
    <<_::binary-size(^off), v::little-16, _::binary>> = d
    v
  end
end
