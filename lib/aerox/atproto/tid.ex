defmodule Aerox.ATProto.TID do
  @moduledoc """
  Timestamp identifiers (DESIGN §3.7). 64 bits: top bit 0, 53 bits of
  microseconds since the Unix epoch, 10 bits of clock id; base32-sortable
  (`234567abcdefghijklmnopqrstuvwxyz`) into 13 characters, so lexical order
  is time order.

  The kernel is process-free, so monotonicity is a *pure* rule here:
  `next/3` takes the previous TID and never returns one that is not strictly
  newer, adding a microsecond on clock regression or repeated calls in the
  same microsecond (a duplicated key makes the MST silently overwrite a
  record). The stateful clock that remembers `prev` lives in the PDS.
  """
  import Bitwise
  alias Aerox.ATProto.Syntax

  @alphabet ~c"234567abcdefghijklmnopqrstuvwxyz"
  @max_timestamp (1 <<< 53) - 1
  @max_clock_id 1023

  @type t :: String.t()

  @doc "Builds a TID from microseconds and a clock id (0..1023)."
  @spec from_time(non_neg_integer, non_neg_integer) :: t
  def from_time(micros, clock_id)
      when is_integer(micros) and micros >= 0 and micros <= @max_timestamp and
             clock_id in 0..@max_clock_id do
    encode_s32(micros <<< 10 ||| clock_id, 13)
  end

  @doc "The next TID after `prev` for the given wall clock, strictly increasing."
  @spec next(t | nil, non_neg_integer, non_neg_integer) :: t
  def next(nil, now_micros, clock_id), do: from_time(now_micros, clock_id)

  def next(prev, now_micros, clock_id) do
    prev_micros = timestamp(prev)
    micros = if now_micros > prev_micros, do: now_micros, else: prev_micros + 1
    from_time(micros, clock_id)
  end

  @doc "Microseconds encoded in the TID."
  @spec timestamp(t) :: non_neg_integer
  def timestamp(<<_::binary-size(13)>> = tid), do: decode_s32(tid) >>> 10

  @spec clock_id(t) :: non_neg_integer
  def clock_id(<<_::binary-size(13)>> = tid), do: decode_s32(tid) &&& @max_clock_id

  @doc "The instant a TID encodes."
  @spec to_datetime(t) :: DateTime.t()
  def to_datetime(tid), do: DateTime.from_unix!(timestamp(tid), :microsecond)

  @spec valid?(term) :: boolean
  def valid?(tid), do: Syntax.valid_tid?(tid)

  @spec parse(term) :: {:ok, t} | {:error, String.t()}
  def parse(tid) do
    case Syntax.ensure_valid_tid(tid) do
      :ok -> {:ok, tid}
      error -> error
    end
  end

  @doc "Lexical comparison is chronological comparison."
  @spec compare(t, t) :: :lt | :eq | :gt
  def compare(a, b) when a < b, do: :lt
  def compare(a, a), do: :eq
  def compare(_, _), do: :gt

  @doc "Sortable base32 encoding of a non-negative integer, left-padded to `width`."
  @spec encode_s32(non_neg_integer, non_neg_integer) :: String.t()
  def encode_s32(int, width) do
    int
    |> Integer.digits(32)
    |> Enum.map(&Enum.at(@alphabet, &1))
    |> List.to_string()
    |> String.pad_leading(width, "2")
  end

  @spec decode_s32(String.t()) :: non_neg_integer
  def decode_s32(str) do
    for <<c <- str>>, reduce: 0 do
      acc -> acc * 32 + Enum.find_index(@alphabet, &(&1 == c))
    end
  end
end
