defmodule Aerox.ATProto.TIDTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise
  alias Aerox.ATProto.TID

  test "round-trips time and clock id, 13 characters, sortable" do
    tid = TID.from_time(1_700_000_000_000_000, 5)
    assert byte_size(tid) == 13
    assert TID.valid?(tid)
    assert TID.timestamp(tid) == 1_700_000_000_000_000
    assert TID.clock_id(tid) == 5
    assert TID.to_datetime(tid) == DateTime.from_unix!(1_700_000_000_000_000, :microsecond)
  end

  test "next is strictly increasing across clock regression and repeated micros" do
    a = TID.next(nil, 1000, 1)
    b = TID.next(a, 1000, 1)
    c = TID.next(b, 999, 1)
    d = TID.next(c, 5000, 1)
    assert a < b and b < c and c < d
    assert TID.timestamp(b) == 1001 and TID.timestamp(c) == 1002 and TID.timestamp(d) == 5000
  end

  test "the upstream example decodes as expected" do
    # from the atproto spec: 3jzfcijpj2z2a
    assert TID.valid?("3jzfcijpj2z2a")
    assert TID.timestamp("3jzfcijpj2z2a") > 0
  end

  property "lexical order is time order" do
    check all(
            a <- integer(0..((1 <<< 53) - 1)),
            b <- integer(0..((1 <<< 53) - 1)),
            c <- integer(0..1023)
          ) do
      ta = TID.from_time(a, c)
      tb = TID.from_time(b, c)

      assert TID.compare(ta, tb) ==
               (cond do
                  a < b -> :lt
                  a == b -> :eq
                  true -> :gt
                end)
    end
  end
end
