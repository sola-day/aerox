Code.require_file("helpers.exs", __DIR__)

defmodule Aerox.Labeler.LabelsTest do
  @moduledoc """
  VERIFICATION §5 Labeler: label signing (upstream `signLabel`'s bytes),
  the `subscribeLabels` sequencer (one `#labels` event per creation, replay
  by cursor), negation as an upsert, and `queryLabels` semantics.
  """
  use Aerox.DataCase, async: false
  alias Aerox.ATProto.{Bytes, Crypto, DagCBOR, Frame}
  alias Aerox.Labeler.{Labels, Repo, Sequencer}
  alias Aerox.Labeler.Schema.Label
  import Aerox.LabelerTestHelpers

  setup do
    labeler = configure_unit_labeler!()
    {:ok, labeler: labeler, since: Sequencer.current() || 0}
  end

  @post "at://did:plc:aaaaaaaaaaaaaaaaaaaaaaaa/app.bsky.feed.post/3kabc"
  @cid "bafyreidfayvfuwqa7qlnopdjiqrxzs6blmoeu4rujcjtnci5beludirz2a"

  test "a created label is signed over the DAG-CBOR of its unsigned wire form", ctx do
    {:ok, label} = Labels.create(%{uri: @post, cid: @cid, val: "spam"})
    assert %Label{src: src, neg: false, ver: 1} = label
    assert src == ctx.labeler.did

    wire = Labels.to_wire(label)

    # upstream field set, in the lexicon's shape: no `neg` when false, no `exp` when absent
    assert Map.keys(wire) |> Enum.sort() == ~w(cid cts sig src uri val ver)
    assert wire["ver"] == 1 and wire["cid"] == @cid
    assert %Bytes{} = wire["sig"]

    unsigned = Map.delete(wire, "sig")
    assert Crypto.verify_did_sig(ctx.labeler.did_key, DagCBOR.encode(unsigned), wire["sig"].data)
    assert Labels.valid_signature?(wire, ctx.labeler.did_key)

    # the stored cts round-trips through the signed string (millisecond precision)
    assert wire["cts"] == Aerox.ATProto.Syntax.format_datetime(label.cts)
    other = Crypto.generate(:k256)
    refute Labels.valid_signature?(wire, Crypto.did_key(other))
  end

  test "each creation sequences one #labels event; rows replay from a cursor as frames", ctx do
    {:ok, a} = Labels.create(%{uri: @post, val: "spam"})

    {:ok, [b, c]} =
      Labels.create_many([
        %{uri: "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb", val: "rude"},
        %{uri: @post, val: "rude"}
      ])

    assert is_integer(a.seq) and b.seq == c.seq and b.seq > a.seq
    rows = Sequencer.range(ctx.since, 100)
    assert Enum.map(rows, & &1.seq) == [a.seq, b.seq]

    [first, second] = Enum.map(rows, &Sequencer.to_frame/1)
    assert {"#labels", %{"seq" => seq, "labels" => [wire]}} = first
    assert seq == a.seq
    assert wire["uri"] == @post and wire["val"] == "spam" and wire["src"] == ctx.labeler.did
    assert Labels.valid_signature?(wire, ctx.labeler.did_key)
    assert {"#labels", %{"labels" => [_, _]}} = second

    # the frame encodes and decodes as the socket sends it
    {t, body} = first
    assert {:ok, {:message, "#labels", ^body}} = Frame.decode(Frame.encode({:message, t, body}))

    # cursor semantics of the source
    assert Sequencer.next_after(a.seq).seq == b.seq
    assert Sequencer.current() == b.seq
  end

  test "negation replaces the row (neg: true) and is sequenced; re-application flips it back",
       ctx do
    {:ok, l1} = Labels.create(%{uri: @post, cid: @cid, val: "spam"})
    assert Labels.applied?(@post, "spam")

    {:ok, l2} = Labels.negate(@post, @cid, "spam")
    assert l2.id == l1.id and l2.neg == true and l2.seq > l1.seq
    refute Labels.applied?(@post, "spam")
    assert Repo.aggregate(Label, :count) == 1

    [_, neg_row] = Sequencer.range(ctx.since, 10)
    assert {"#labels", %{"labels" => [%{"neg" => true} = wire]}} = Sequencer.to_frame(neg_row)
    assert Labels.valid_signature?(wire, ctx.labeler.did_key)

    {:ok, l3} = Labels.create(%{uri: @post, cid: @cid, val: "spam"})
    assert l3.id == l1.id and l3.neg == false
    assert Labels.applied?(@post, "spam")
  end

  test "expired labels are not applied; exp is signed and served", _ctx do
    past = DateTime.add(DateTime.utc_now(), -60, :second)
    {:ok, l} = Labels.create(%{uri: @post, val: "spam", exp: past})
    refute Labels.applied?(@post, "spam")
    assert Labels.to_wire(l)["exp"] == Aerox.ATProto.Syntax.format_datetime(l.exp)
  end

  test "queryLabels: exact URIs, prefix wildcards, sources, limit and cursor", ctx do
    did = "did:plc:cccccccccccccccccccccccc"
    p1 = "at://#{did}/app.bsky.feed.post/1"
    p2 = "at://#{did}/app.bsky.feed.post/2"
    other = "at://did:plc:dddddddddddddddddddddddd/app.bsky.feed.post/1"

    {:ok, _} =
      Labels.create_many([
        %{uri: p1, val: "spam"},
        %{uri: p2, val: "rude"},
        %{uri: other, val: "spam"},
        %{uri: did, val: "rude"}
      ])

    uris = fn {rows, _} -> Enum.map(rows, & &1.uri) end

    assert {:ok, r} = Labels.query(%{uri_patterns: [p1]})
    assert uris.(r) == [p1]

    assert {:ok, r} = Labels.query(%{uri_patterns: ["at://#{did}/*"]})
    assert uris.(r) == [p1, p2]

    assert {:ok, r} = Labels.query(%{uri_patterns: [did, other]})
    assert uris.(r) == [other, did]

    assert {:ok, r} = Labels.query(%{uri_patterns: ["*"]})
    assert length(elem(r, 0)) == 4

    assert {:ok, r} = Labels.query(%{uri_patterns: ["*"], sources: [ctx.labeler.did]})
    assert length(elem(r, 0)) == 4

    assert {:ok, {[], nil}} =
             Labels.query(%{uri_patterns: ["*"], sources: ["did:web:nobody.example"]})

    # paging by id
    assert {:ok, {page1, cursor}} = Labels.query(%{uri_patterns: ["*"], limit: 3})
    assert length(page1) == 3 and cursor == Integer.to_string(List.last(page1).id)
    assert {:ok, {page2, _}} = Labels.query(%{uri_patterns: ["*"], limit: 3, cursor: cursor})
    assert Enum.map(page2, & &1.uri) == [did]

    assert {:error, "invalid pattern: " <> _} = Labels.query(%{uri_patterns: ["at://*/x"]})
    assert {:error, "invalid cursor"} = Labels.query(%{uri_patterns: ["*"], cursor: "abc"})

    # `_` in a prefix is literal, not a LIKE wildcard
    {:ok, _} = Labels.create(%{uri: "at://#{did}/app.bsky.feed.post/a_b", val: "spam"})
    {:ok, _} = Labels.create(%{uri: "at://#{did}/app.bsky.feed.post/axb", val: "spam"})
    assert {:ok, r} = Labels.query(%{uri_patterns: ["at://#{did}/app.bsky.feed.post/a_*"]})
    assert uris.(r) == ["at://#{did}/app.bsky.feed.post/a_b"]
  end
end
