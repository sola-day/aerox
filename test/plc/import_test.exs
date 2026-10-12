defmodule Aerox.PLC.ImportTest do
  @moduledoc "Copying another directory's log: validated per DID before any write, verbatim rows in source order, re-runnable, and paged `/export` reads that survive shared timestamps."
  use Aerox.DataCase, async: true, repos: [Aerox.PLC.Repo]
  alias Aerox.ATProto.{Crypto, Syntax}
  alias Aerox.PLC.{Directory, Import, Operations}

  @moduletag :service

  @t0 ~U[2026-08-21 10:56:19.872000Z]

  setup do
    {key_a, a0, did_a} = genesis("alice.test")
    {_key_b, b0, did_b} = genesis("bob.test")
    a1 = Operations.atproto_update_op(a0, key_a, handle: "alice2.test")
    # b0 shares a1's millisecond, as ops do in a bulk mirror
    log = [entry(did_a, a0, 0), entry(did_a, a1, 116), entry(did_b, b0, 116)]
    {:ok, log: log, did_a: did_a, did_b: did_b, key_a: key_a, a1: a1}
  end

  test "writes every DID's log verbatim and in order, and a rerun adds nothing", ctx do
    assert {:ok, %{dids: 2, added: 3}} = Import.run(ctx.log)
    assert {:ok, %{"alsoKnownAs" => ["at://alice2.test"]}} = Directory.did_document(ctx.did_a)
    assert Directory.audit_log(ctx.did_a) == Enum.take(ctx.log, 2)
    assert Enum.map(Directory.export(10, 0), & &1["cid"]) == Enum.map(ctx.log, & &1["cid"])
    assert {:ok, %{added: 0}} = Import.run(ctx.log)
  end

  test "an existing prefix is completed; a diverging history is refused", ctx do
    assert {:ok, %{added: 1}} = Import.run(Enum.take(ctx.log, 1))
    assert {:ok, %{added: 2}} = Import.run(ctx.log)

    other = Operations.atproto_update_op(ctx.a1, ctx.key_a, handle: "elsewhere.test")
    forked = List.replace_at(ctx.log, 1, entry(ctx.did_a, other, 116))
    assert {:error, [{did, :differs_from_existing_log}]} = Import.run(forked)
    assert did == ctx.did_a
  end

  test "one invalid log stops the whole import before anything is written", ctx do
    tampered =
      update_in(Enum.at(ctx.log, 2), ["operation", "alsoKnownAs"], fn _ -> ["at://x.test"] end)

    assert {:error, [{did, {:error, _}}]} = Import.run(List.replace_at(ctx.log, 2, tampered))
    assert did == ctx.did_b
    assert Directory.export(10, 0) == []
  end

  test "reads a directory's /export page by page, across ops sharing a millisecond", ctx do
    Req.Test.stub(Import, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      count = String.to_integer(conn.query_params["count"])

      after_ =
        case conn.query_params["after"] do
          nil -> nil
          at -> at |> DateTime.from_iso8601() |> elem(1)
        end

      lines =
        ctx.log
        |> Enum.filter(&(is_nil(after_) or DateTime.compare(at(&1), after_) == :gt))
        |> Enum.take(count)

      Plug.Conn.send_resp(conn, 200, Enum.map_join(lines, "\n", &Jason.encode!/1))
    end)

    # the first page is full; the second starts 1 ms before its last op and
    # meets the shared timestamp again
    assert Import.read!("https://plc.example/", 3) == ctx.log
  end

  defp genesis(handle) do
    key = Crypto.generate(:k256)
    opts = [signing_key: Crypto.did_key(key), handle: handle, pds: "https://pds.test"]
    {op, did} = Operations.create_op(opts ++ [rotation_keys: [Crypto.did_key(key)]], key)
    {key, op, did}
  end

  defp entry(did, op, ms) do
    %{
      "did" => did,
      "operation" => op,
      "cid" => op |> Operations.cid() |> to_string(),
      "nullified" => false,
      "createdAt" => @t0 |> DateTime.add(ms, :millisecond) |> Syntax.format_datetime()
    }
  end

  defp at(entry), do: entry["createdAt"] |> DateTime.from_iso8601() |> elem(1)
end
