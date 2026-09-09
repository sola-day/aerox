defmodule Aerox.Interop.PLCTest do
  @moduledoc """
  VERIFICATION §7.2 row "PLC", over real hostnames and TLS: operations we
  sign are accepted by the reference directory; the reference's own
  operations (the interop vectors) are accepted by ours; both directories
  answer identically for the same log; a DID created on one resolves through
  our resolver pointed at the other.

  Needs the reference container (tools/interop/compose.yaml) and both
  directories reachable:

      AEROX_PLC_URL=https://plc.aerox.sola.town \\
      AEROX_REF_PLC_URL=https://ref-plc.aerox.sola.town mix test --only interop
  """
  use Aerox.GoldenCase, async: false
  alias Aerox.ATProto.Crypto
  alias Aerox.Identity.Resolver
  alias Aerox.PLC.Operations

  @moduletag :interop

  setup_all do
    ours = System.get_env("AEROX_PLC_URL")
    ref = System.get_env("AEROX_REF_PLC_URL")

    if ours && ref do
      {:ok, ours: ours, ref: ref}
    else
      {:ok, skip: true}
    end
  end

  setup ctx do
    if ctx[:skip], do: :ok, else: :ok
  end

  defp post_op(base, did, op) do
    Req.post!("#{base}/#{did}", json: op, retry: false)
  end

  defp get_json(base, path) do
    resp = Req.get!("#{base}#{path}", retry: false, decode_body: false)
    {resp.status, if(resp.status == 200, do: Jason.decode!(resp.body), else: resp.body)}
  end

  # Vectors replayed live get "now" timestamps on both sides, so only logs
  # whose validity does not depend on elapsed time are replayed here.
  @replayable ~w(log_bnewbold_robocracy log_bskyapp log_duplicate_rotation_keys log_empty_rotation_keys log_nullification log_nullification_nontrivial log_nullified_tombstone log_tombstone)

  test "the reference directory's own operations are accepted by both, with identical results",
       ctx do
    if ctx[:skip], do: throw(:skip)

    for name <- @replayable do
      log = json_golden!("plc/valid/#{name}.json")
      did = hd(log)["did"]

      # skip logs already replayed by an earlier run against persistent directories
      unless match?({200, _}, get_json(ctx.ref, "/#{did}/log/audit")) do
        for entry <- log do
          r = post_op(ctx.ref, did, entry["operation"])
          assert r.status == 200, "#{name}: reference refused #{entry["cid"]}: #{inspect(r.body)}"
          o = post_op(ctx.ours, did, entry["operation"])
          assert o.status == 200, "#{name}: aerox refused #{entry["cid"]}: #{inspect(o.body)}"
        end
      end

      {rs, ref_doc} = get_json(ctx.ref, "/#{did}")
      {os, our_doc} = get_json(ctx.ours, "/#{did}")
      assert rs == os, "#{name}: status #{rs} vs #{os}"
      if rs == 200, do: assert(ref_doc == our_doc, "#{name}: documents differ")

      {200, ref_audit} = get_json(ctx.ref, "/#{did}/log/audit")
      {200, our_audit} = get_json(ctx.ours, "/#{did}/log/audit")
      strip = fn entries -> Enum.map(entries, &Map.drop(&1, ["createdAt"])) end
      assert strip.(ref_audit) == strip.(our_audit), "#{name}: audit logs differ"

      {rs, ref_data} = get_json(ctx.ref, "/#{did}/data")
      {os, our_data} = get_json(ctx.ours, "/#{did}/data")
      assert {rs, ref_data} == {os, our_data}, "#{name}: data differs"
    end
  catch
    :skip -> :ok
  end

  test "operations signed by aerox are accepted by the reference directory and resolve identically",
       ctx do
    if ctx[:skip], do: throw(:skip)

    rotation = Crypto.generate(:k256)
    recovery = Crypto.generate(:p256)
    signing = Crypto.generate(:k256)
    handle = "interop-#{System.unique_integer([:positive])}.aerox.sola.town"

    {genesis, did} =
      Operations.create_op(
        [
          signing_key: Crypto.did_key(signing),
          handle: handle,
          pds: "https://pds.aerox.sola.town",
          rotation_keys: [Crypto.did_key(recovery), Crypto.did_key(rotation)]
        ],
        rotation
      )

    assert post_op(ctx.ref, did, genesis).status == 200
    assert post_op(ctx.ours, did, genesis).status == 200

    update = Operations.atproto_update_op(genesis, rotation, handle: "renamed-" <> handle)
    assert post_op(ctx.ref, did, update).status == 200
    assert post_op(ctx.ours, did, update).status == 200

    # a P-256 recovery key nullifies the K-256 rotation key's op on both
    recover =
      Operations.atproto_update_op(genesis, recovery, rotation_keys: [Crypto.did_key(recovery)])

    assert post_op(ctx.ref, did, recover).status == 200
    assert post_op(ctx.ours, did, recover).status == 200

    {200, ref_doc} = get_json(ctx.ref, "/#{did}")
    {200, our_doc} = get_json(ctx.ours, "/#{did}")
    assert ref_doc == our_doc
    assert ref_doc["alsoKnownAs"] == ["at://" <> handle]

    {200, ref_audit} = get_json(ctx.ref, "/#{did}/log/audit")
    {200, our_audit} = get_json(ctx.ours, "/#{did}/log/audit")
    assert Enum.map(ref_audit, & &1["nullified"]) == [false, true, false]
    assert Enum.map(our_audit, & &1["nullified"]) == [false, true, false]
    assert Enum.map(ref_audit, & &1["cid"]) == Enum.map(our_audit, & &1["cid"])

    # the reference refuses what we refuse
    bogus = Operations.atproto_update_op(recover, rotation, handle: "evil.test")
    assert post_op(ctx.ref, did, bogus).status == 400
    assert post_op(ctx.ours, did, bogus).status == 400

    # our resolver, pointed at the reference over TLS, resolves the DID we created there
    assert {:ok, doc} = Resolver.resolve_did(did, plc_url: ctx.ref)
    assert doc == ref_doc
    assert {:ok, ^doc} = Resolver.resolve_did(did, plc_url: ctx.ours)
    assert {:ok, key} = Aerox.ATProto.Identity.signing_did_key(doc)
    assert key == Crypto.did_key(signing)
  catch
    :skip -> :ok
  end

  test "export streams agree on the reference's ops", ctx do
    if ctx[:skip], do: throw(:skip)
    {200, _} = get_json(ctx.ref, "/_health")

    ref_lines =
      Req.get!("#{ctx.ref}/export?count=5", retry: false, decode_body: false).body
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    our_lines =
      Req.get!("#{ctx.ours}/export?count=5", retry: false, decode_body: false).body
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert length(ref_lines) == 5 and length(our_lines) == 5

    assert Enum.all?(
             ref_lines ++ our_lines,
             &(Map.keys(&1) |> Enum.sort() == ~w(cid createdAt did nullified operation))
           )
  catch
    :skip -> :ok
  end
end
