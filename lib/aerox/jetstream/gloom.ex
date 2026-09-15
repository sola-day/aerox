defmodule Aerox.Jetstream.Gloom do
  @moduledoc """
  The `github.com/jcalabro/gloom` v0.1.0 bloom filter, which Jetstream segment
  footers carry in its `MarshalBinary` form: a blocked filter of 512-bit blocks
  with prime-partitioned bit positions, an item placed by XXH3-128 (the high
  word picks the block, the folded low word the bits in it).

  Serialized: `version (1) · k u32 · num_blocks u64 · count u64 · words ·
  crc32c u32`, all little-endian. `new/2` sizes a filter exactly as gloom's
  `OptimalParams` does.
  """
  import Bitwise
  alias Aerox.Jetstream.{CRC32C, XXH3}

  @block_bits 512
  @block_words 8
  @ln2_squared 0.4804530139182014
  @min_k 3
  @max_k 17
  @growth_cap 4.0

  @primes %{
    3 => [167, 173, 172],
    4 => [109, 127, 137, 139],
    5 => [97, 101, 103, 109, 102],
    6 => [61, 79, 83, 89, 97, 103],
    7 => [61, 67, 71, 79, 83, 89, 62],
    8 => [37, 47, 53, 61, 67, 71, 79, 97],
    9 => [41, 43, 47, 53, 59, 67, 71, 73, 58],
    10 => [31, 37, 41, 43, 47, 53, 59, 61, 67, 73],
    11 => [29, 31, 37, 41, 43, 44, 47, 53, 59, 61, 67],
    12 => [17, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 71],
    13 => [17, 19, 23, 29, 31, 37, 41, 43, 47, 52, 53, 59, 61],
    14 => [11, 13, 17, 19, 23, 29, 31, 37, 41, 47, 53, 59, 61, 71],
    15 => [11, 13, 17, 19, 23, 28, 29, 31, 37, 41, 43, 47, 53, 59, 61],
    16 => [5, 7, 11, 13, 17, 19, 23, 27, 29, 31, 37, 41, 43, 47, 53, 109],
    17 => [3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 32, 37, 41, 43, 47, 53, 101]
  }

  defstruct [:num_blocks, :k, count: 0, words: %{}, raw: nil]

  @type t :: %__MODULE__{}

  @doc "A filter for `expected_items` at `fp_rate` (gloom `New`)."
  @spec new(non_neg_integer, float) :: t
  def new(expected_items, fp_rate) do
    {num_blocks, k} = optimal_params(expected_items, fp_rate)
    %__MODULE__{num_blocks: max(num_blocks, 1), k: k}
  end

  @doc "Adds a string (gloom `AddString`)."
  @spec add(t, binary) :: t
  def add(%__MODULE__{raw: nil} = f, item) do
    {block, intra} = place(item, f.num_blocks)

    words =
      f.k
      |> bit_positions(intra)
      |> Enum.reduce(f.words, fn pos, words ->
        idx = block * @block_words + div(pos, 64)
        Map.update(words, idx, 1 <<< rem(pos, 64), &(&1 ||| 1 <<< rem(pos, 64)))
      end)

    %{f | words: words, count: f.count + 1}
  end

  @doc "May the filter contain `item`? (gloom `TestString`)"
  @spec member?(t, binary) :: boolean
  def member?(%__MODULE__{} = f, item) do
    {block, intra} = place(item, f.num_blocks)

    Enum.all?(bit_positions(f.k, intra), fn pos ->
      (word(f, block * @block_words + div(pos, 64)) &&& 1 <<< rem(pos, 64)) != 0
    end)
  end

  @doc "gloom `MarshalBinary`."
  @spec marshal(t) :: binary
  def marshal(%__MODULE__{} = f) do
    words =
      case f.raw do
        nil ->
          for i <- 0..(f.num_blocks * @block_words - 1),
              into: <<>>,
              do: <<Map.get(f.words, i, 0)::little-64>>

        raw ->
          raw
      end

    body = <<1, f.k::little-32, f.num_blocks::little-64, f.count::little-64, words::binary>>
    <<body::binary, CRC32C.checksum(body)::little-32>>
  end

  @doc "gloom `UnmarshalBinary`."
  @spec unmarshal(binary) :: {:ok, t} | {:error, term}
  def unmarshal(<<1, k::little-32, num_blocks::little-64, count::little-64, rest::binary>> = data) do
    words_len = num_blocks * @block_words * 8
    payload_len = byte_size(data) - 4

    cond do
      not Map.has_key?(@primes, k) ->
        {:error, :invalid_k}

      num_blocks == 0 ->
        {:error, :invalid_num_blocks}

      byte_size(rest) != words_len + 4 ->
        {:error, :length_mismatch}

      true ->
        <<payload::binary-size(^payload_len), crc::little-32>> = data

        if CRC32C.checksum(payload) == crc do
          <<words::binary-size(^words_len), _::binary>> = rest
          {:ok, %__MODULE__{num_blocks: num_blocks, k: k, count: count, raw: words}}
        else
          {:error, :checksum_mismatch}
        end
    end
  end

  def unmarshal(<<v, _::binary>>) when v != 1, do: {:error, :unsupported_version}
  def unmarshal(_), do: {:error, :invalid_data}

  # ------------------------------------------------------------ hashing

  defp place(item, num_blocks) do
    {hi, lo} = XXH3.hash128(item)
    {(hi * num_blocks) >>> 64, bxor(lo &&& 0xFFFFFFFF, lo >>> 32)}
  end

  defp bit_positions(k, intra) do
    primes = Map.fetch!(@primes, k)

    {positions, _} =
      Enum.map_reduce(primes, 0, fn p, offset -> {offset + rem(intra, p), offset + p} end)

    positions
  end

  defp word(%__MODULE__{raw: nil, words: words}, idx), do: Map.get(words, idx, 0)

  defp word(%__MODULE__{raw: raw}, idx) do
    <<_::binary-size(^idx * 8), w::little-64, _::binary>> = raw
    w
  end

  # ------------------------------------------------------------- sizing

  @doc "gloom `OptimalParams`: `{num_blocks, k}`."
  @spec optimal_params(non_neg_integer, float) :: {pos_integer, pos_integer}
  def optimal_params(expected, fp) do
    expected = if expected == 0, do: 1, else: expected

    fp =
      cond do
        fp <= 0 -> 0.0001
        fp >= 1 -> 0.99
        true -> fp
      end

    bits_per_item = -:math.log(fp) / @ln2_squared
    base = ceil_int(expected * bits_per_item / @block_bits)
    max_blocks = ceil_int(base * @growth_cap)
    grow(base, best_k(base, expected), expected, fp, max_blocks)
  end

  defp grow(blocks, k, expected, fp, max_blocks) do
    if estimate_fp(blocks, k, expected) > fp and blocks < max_blocks do
      next = min(blocks + div(blocks, 8) + 1, max_blocks)
      grow(next, best_k(next, expected), expected, fp, max_blocks)
    else
      {blocks, k}
    end
  end

  defp best_k(blocks, expected) do
    {k, _} =
      Enum.reduce(@min_k..@max_k, {@min_k, nil}, fn k, {best, best_fp} ->
        fp = estimate_fp(blocks, k, expected)
        if best_fp == nil or fp < best_fp, do: {k, fp}, else: {best, best_fp}
      end)

    k
  end

  @doc "gloom `EstimateFalsePositiveRate`."
  def estimate_fp(0, _k, _items), do: 0.0
  def estimate_fp(_blocks, _k, 0), do: 0.0

  def estimate_fp(blocks, k, items) do
    primes = Map.get(@primes, k)
    lambda = items / blocks

    if lambda > 10_000 do
      partitioned_fp(primes, lambda)
    else
      max_j = trunc(lambda + 10 * :math.sqrt(lambda) + 20)
      log_lambda = :math.log(lambda)

      Enum.reduce_while(0..max_j, {0.0, 0.0}, fn j, {fp, log_fact} ->
        log_fact = if j > 0, do: log_fact + :math.log(j), else: log_fact
        prob = safe_exp(-lambda + j * log_lambda - log_fact)

        cond do
          prob < 1.0e-15 and j > trunc(lambda) -> {:halt, {fp, log_fact}}
          j > 0 -> {:cont, {fp + prob * partitioned_fp(primes, j), log_fact}}
          true -> {:cont, {fp, log_fact}}
        end
      end)
      |> elem(0)
    end
  end

  defp partitioned_fp(primes, j) do
    Enum.reduce(primes, 1.0, fn p, acc -> acc * (1 - :math.pow(1 - 1 / p, j)) end)
  end

  defp safe_exp(x) when x < -745.0, do: 0.0
  defp safe_exp(x), do: :math.exp(x)

  defp ceil_int(x) do
    t = trunc(x)
    if x > t, do: t + 1, else: t
  end
end
