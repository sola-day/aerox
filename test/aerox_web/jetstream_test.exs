defmodule AeroxWeb.JetstreamTest do
  @moduledoc """
  Jetstream's HTTP surface: subscribe upgrade validation (v1 plain text, v2
  XRPC errors), the subscriber process (replay, filters, options_update,
  requireHello, v2 push-only, compression), the archive endpoints with
  ranges and ETags, planSnapshot, getZstdDictionary, and the timestamp import.
  """
  use Aerox.JetstreamCase, async: false
  import Phoenix.ConnTest
  import Plug.Conn
  alias Aerox.ATProto.DagCBOR
  alias Aerox.Jetstream.{Block, Compactor, Importer, Segment, Store, Wire}
  alias AeroxWeb.Sockets.Jetstream, as: Socket

  @endpoint AeroxWeb.Endpoint

  setup do
    Aerox.RateLimit.reset()
    Store.put("phase", "steady_state")
    conn = %{build_conn() | host: Aerox.Jetstream.Config.hostname()}
    {:ok, conn: conn}
  end

  defp ws(conn),
    do:
      conn
      |> put_req_header("connection", "Upgrade")
      |> put_req_header("upgrade", "websocket")
      |> put_req_header("sec-websocket-version", "13")
      |> put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")

  # drive the subscriber process by hand: init, then pumps until it waits
  defp drain(state, acc \\ []) do
    receive do
      :pump ->
        case Socket.handle_info(:pump, state) do
          {:push, frames, state} -> drain(state, acc ++ frames)
          {:ok, state} -> {acc, state}
          {:stop, _, _, frames, state} -> {acc ++ frames, Map.put(state, :stopped, true)}
        end
    after
      0 -> {acc, state}
    end
  end

  defp subscriber(opts) do
    base = %{
      v2: false,
      filter: %Aerox.Jetstream.Filter{},
      compress: false,
      cursor: 1,
      require_hello: false
    }

    state = Map.merge(base, Map.new(opts))

    case Socket.init(state) do
      {:ok, state} -> {[], state}
      {:push, frame, state} -> {[frame], state}
    end
  end

  describe "upgrade validation" do
    test "v2: XRPC errors before the upgrade", %{conn: conn} do
      path = "/xrpc/network.bsky.jetstream.subscribeEvents"

      err = fn query ->
        r = conn |> ws() |> get(path <> "?" <> query)
        {r.status, Jason.decode!(r.resp_body)}
      end

      assert {400,
              %{"error" => "InvalidRequest", "message" => "invalid options: wantedDids" <> _}} =
               err.("wantedDids=did:plc:a")

      assert {400, %{"error" => "InvalidRequest"}} = err.("kinds=bogus")

      assert {400,
              %{
                "error" => "InvalidRequest",
                "message" => "invalid options: collections filter can never apply" <> _
              }} = err.("kinds=identity&collections=app.bsky.feed.post")

      assert {400, %{"error" => "UnknownZstdDictionary", "message" => msg}} =
               err.("zstdDictionary=7")

      assert msg =~ "20260811"
      assert {400, %{"error" => "InvalidRequest"}} = err.("compress=true")
      assert {400, %{"error" => "InvalidRequest"}} = err.("cursor=-3")

      # a seq cursor below the lookback floor is refused on v2 only
      {:ok, _} = Writer.append([create("did:plc:old", 1)])
      :ok = Writer.rotate()
      [seg] = Manifest.sealed()
      env = Application.get_env(:aerox, Aerox.Jetstream)
      Application.put_env(:aerox, Aerox.Jetstream, Keyword.put(env, :lookback_ms, 0))
      :ok = Writer.rotate()
      {:ok, _} = Writer.append([create("did:plc:old", 2)])
      :ok = Writer.rotate()
      floor = Manifest.lookback_floor(0)
      assert floor > seg.header.min_seq
      assert {400, %{"error" => "CursorTooOld"}} = err.("cursor=#{seg.header.min_seq}")
      v1 = conn |> ws() |> get("/subscribe?cursor=#{seg.header.min_seq}")
      assert v1.status == 101 or v1.halted

      Store.put("phase", "bootstrap")
      assert {503, %{"error" => "ServiceUnavailable"}} = err.("")
    end

    test "v1: plain-text errors; a request without an upgrade is 426", %{conn: conn} do
      r = conn |> ws() |> get("/subscribe?wantedDids=nope")
      assert r.status == 400 and r.resp_body =~ "invalid DID"
      assert get(conn, "/subscribe").status == 426
    end
  end

  describe "the subscriber" do
    test "v1 replays from the cursor, filters collections but passes identity, updates options" do
      {:ok, [p1, _like, id, p2]} =
        Writer.append([
          create("did:plc:s1", 1),
          create("did:plc:s1", 2, "app.bsky.feed.like"),
          %Event{
            kind: :identity,
            did: "did:plc:s1",
            payload:
              DagCBOR.encode(%{
                "did" => "did:plc:s1",
                "handle" => "s1.test",
                "seq" => 1,
                "time" => "2026-09-15T00:00:00.000Z"
              })
          },
          create("did:plc:s2", 3)
        ])

      {:ok, filter} =
        Aerox.Jetstream.Filter.v1(
          Aerox.Jetstream.Filter.pairs("wantedCollections=app.bsky.feed.post")
        )

      {[], state} = subscriber(filter: filter, cursor: p1.seq)
      {frames, state} = drain(state)
      decoded = Enum.map(frames, fn {:text, t} -> Jason.decode!(t) end)
      assert Enum.map(decoded, & &1["cursor"]) == [p1.seq, id.seq, p2.seq]
      assert Enum.map(decoded, & &1["kind"]) == ["commit", "identity", "commit"]
      assert state.waiting

      # new rows wake it; an options_update narrows it to one DID
      update =
        Jason.encode!(%{
          "type" => "options_update",
          "payload" => %{"wantedDids" => ["did:plc:s2"]}
        })

      {:ok, state} = Socket.handle_in({update, [opcode: :text]}, state)
      {:ok, [_, p4]} = Writer.append([create("did:plc:s1", 4), create("did:plc:s2", 5)])
      {:ok, state} = Socket.handle_info({:jetstream_appended, p4.seq}, state)
      {frames, _} = drain(state)
      assert [{:text, t}] = frames
      assert Jason.decode!(t)["cursor"] == p4.seq

      # a malformed update closes the connection
      assert {:stop, :normal, {1008, _}, _} =
               Socket.handle_in(
                 {Jason.encode!(%{
                    "type" => "options_update",
                    "payload" => %{"wantedDids" => ["x"]}
                  }), [opcode: :text]},
                 state
               )
    end

    test "requireHello holds replay until the first options_update" do
      {:ok, [row]} = Writer.append([create("did:plc:hello", 1)])
      {[], state} = subscriber(cursor: row.seq, require_hello: true)
      refute_received :pump

      {:ok, state} =
        Socket.handle_in(
          {Jason.encode!(%{"type" => "options_update", "payload" => %{}}), [opcode: :text]},
          state
        )

      assert {[{:text, _}], _} = drain(state)
    end

    test "v2: xrpc.v1.json frames, compression, the OutdatedCursor info, push only" do
      {:ok, [row, sync]} =
        Writer.append([
          create("did:plc:v2", 1),
          %Event{
            kind: :sync,
            did: "did:plc:v2",
            rev: "3kaaaaaaaaa22",
            payload:
              DagCBOR.encode(%{
                "did" => "did:plc:v2",
                "rev" => "3kaaaaaaaaa22",
                "blocks" => Aerox.ATProto.Bytes.new(<<1>>),
                "seq" => 2,
                "time" => "2026-09-15T00:00:00.000Z"
              })
          }
        ])

      {:ok, filter} = Aerox.Jetstream.Filter.v2([{"kinds", "sync"}])

      {[info], state} =
        subscriber(v2: true, compress: true, filter: filter, cursor: row.seq, info: "clamped")

      assert {:binary, z} = info

      assert %{"payload" => %{"name" => "OutdatedCursor"}} =
               Jason.decode!(Wire.decompress(:v2, z))

      {[{:binary, z2}], state} = drain(state)

      assert %{
               "payload" => %{
                 "$type" => "network.bsky.jetstream.subscribeEvents#sync",
                 "seq" => seq
               }
             } = Jason.decode!(Wire.decompress(:v2, z2))

      assert seq == sync.seq

      assert {:stop, :normal, 1008, _} = Socket.handle_in({"hi", [opcode: :text]}, state)
    end
  end

  describe "the archive" do
    setup do
      {:ok, a} = Writer.append(for n <- 1..4, do: create("did:plc:arch-a", n))
      :ok = Writer.rotate()

      {:ok, b} =
        Writer.append(for n <- 5..8, do: create("did:plc:arch-b", n, "app.bsky.feed.like"))

      {:ok, c} =
        Writer.append([
          %Event{
            kind: :identity,
            did: "did:plc:arch-c",
            payload:
              DagCBOR.encode(%{
                "did" => "did:plc:arch-c",
                "seq" => 1,
                "time" => "2026-09-15T00:00:00.000Z"
              })
          }
        ])

      :ok = Writer.rotate()
      {:ok, rows: %{a: a, b: b, c: c}}
    end

    test "listSegments, getSegment with ETag and Range, getBlock", %{conn: conn} do
      body =
        conn |> get("/xrpc/network.bsky.jetstream.listSegments?limit=1") |> json_response(200)

      assert [
               %{
                 "name" => "seg_0000000000.jss",
                 "index" => 0,
                 "eventCount" => 4,
                 "checksum" => checksum
               } = s0
             ] = body["segments"]

      assert body["cursor"] == "1"

      page2 =
        conn |> get("/xrpc/network.bsky.jetstream.listSegments?cursor=1") |> json_response(200)

      assert [%{"index" => 1, "eventCount" => 5}] = page2["segments"]
      refute Map.has_key?(page2, "cursor")

      full = get(conn, "/xrpc/network.bsky.jetstream.getSegment?name=seg_0000000000.jss")
      assert full.status == 200
      assert get_resp_header(full, "etag") == [~s("#{checksum}")]
      assert byte_size(full.resp_body) == s0["sizeBytes"]
      assert {:ok, parsed} = Segment.parse(full.resp_body)

      assert Integer.to_string(parsed.header.checksum, 16)
             |> String.downcase()
             |> String.pad_leading(16, "0") == checksum

      assert conn
             |> put_req_header("if-none-match", ~s("#{checksum}"))
             |> get("/xrpc/network.bsky.jetstream.getSegment?name=seg_0000000000.jss")
             |> Map.get(:status) == 304

      ranged =
        conn
        |> put_req_header("range", "bytes=0-11")
        |> get("/xrpc/network.bsky.jetstream.getSegment?name=seg_0000000000.jss")

      assert ranged.status == 206 and ranged.resp_body == binary_part(full.resp_body, 0, 12)

      block =
        get(conn, "/xrpc/network.bsky.jetstream.getBlock?segment=seg_0000000000.jss&blockIndex=1")

      assert block.status == 200
      assert {:ok, [%{did: "did:plc:arch-a"} | _], _} = Block.decompress(block.resp_body)
      assert get_resp_header(block, "etag") == [~s("#{checksum}:1")]

      assert %{"error" => "BlockNotFound"} =
               conn
               |> get(
                 "/xrpc/network.bsky.jetstream.getBlock?segment=seg_0000000000.jss&blockIndex=99"
               )
               |> json_response(404)

      assert %{"error" => "SegmentNotFound"} =
               conn
               |> get("/xrpc/network.bsky.jetstream.getSegment?name=seg_00000000zz.jss")
               |> json_response(404)

      assert %{"error" => "InvalidRequest"} =
               conn
               |> get("/xrpc/network.bsky.jetstream.getSegment?name=nope")
               |> json_response(400)
    end

    test "planSnapshot selects by DID, collection and kind; pages hold whole units", %{
      conn: conn,
      rows: rows
    } do
      plan = fn input ->
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/xrpc/network.bsky.jetstream.planSnapshot", Jason.encode!(input))
        |> json_response(200)
      end

      everything = plan.(%{})
      assert everything["sealedTipSeq"] == List.last(rows.c).seq
      assert everything["plannedThroughSeq"] == everything["sealedTipSeq"]
      assert Enum.map(everything["segments"], & &1["mode"]) == ["segment", "segment"]

      by_did = plan.(%{"dids" => ["did:plc:arch-a"]})
      assert [%{"index" => 0}] = by_did["segments"]

      likes =
        plan.(%{
          "collections" => ["app.bsky.feed.*"],
          "kinds" => ["commit"],
          "afterSeq" => List.last(rows.a).seq
        })

      assert [%{"index" => 1}] = likes["segments"]

      identity = plan.(%{"kinds" => ["identity"]})
      assert [%{"index" => 1, "mode" => mode} = seg] = identity["segments"]
      assert mode == "blocks" and seg["blocks"] == [%{"first" => 1, "last" => 1}]

      assert %{"error" => "InvalidRequest"} =
               conn
               |> put_req_header("content-type", "application/json")
               |> post(
                 "/xrpc/network.bsky.jetstream.planSnapshot",
                 Jason.encode!(%{
                   "kinds" => ["identity"],
                   "collections" => ["app.bsky.feed.post"]
                 })
               )
               |> json_response(400)

      assert %{"error" => "InvalidRequest"} =
               conn
               |> put_req_header("content-type", "application/json")
               |> post(
                 "/xrpc/network.bsky.jetstream.planSnapshot",
                 Jason.encode!(%{"afterSeq" => 5, "beforeSeq" => 5})
               )
               |> json_response(400)
    end

    test "getZstdDictionary", %{conn: conn} do
      r = get(conn, "/xrpc/network.bsky.jetstream.getZstdDictionary")
      assert r.status == 200 and r.resp_body == Wire.dictionary(:v2)
      assert get_resp_header(r, "x-zstd-dictionary-id") == ["20260811"]

      assert conn
             |> get("/xrpc/network.bsky.jetstream.getZstdDictionary?id=20260811")
             |> Map.get(:status) == 200

      assert %{"error" => "DictionaryNotFound"} =
               conn
               |> get("/xrpc/network.bsky.jetstream.getZstdDictionary?id=1")
               |> json_response(404)
    end
  end

  test "timestamp import: bearer, rules for new rows, patched sealed rows", %{
    conn: conn,
    dir: dir
  } do
    start_supervised!(Compactor)
    start_supervised!(Importer)
    {:ok, [target, other]} = Writer.append([create("did:plc:ts", 1), create("did:plc:ts", 2)])
    :ok = Writer.rotate()

    import_dir = Path.join(dir, "imports")
    File.mkdir_p!(import_dir)
    uri = "at://did:plc:ts/app.bsky.feed.post/#{target.rkey}"

    File.write!(Path.join(import_dir, "ts.csv"), """
    timestamp,uri
    2022-01-02T03:04:05Z,#{uri}
    not-a-time,at://did:plc:ts/app.bsky.feed.post/x
    """)

    post_import = fn c, body ->
      c
      |> put_req_header("content-type", "application/json")
      |> post("/xrpc/network.bsky.jetstream.importTimestamps", Jason.encode!(body))
    end

    assert post_import.(conn, %{path: "ts.csv"}).status == 401

    authed = put_req_header(conn, "authorization", "Bearer jetstream-import-token")

    assert %{"error" => "InvalidPath"} =
             post_import.(authed, %{path: "../../etc/passwd"}) |> json_response(400)

    assert %{"job" => job} = post_import.(authed, %{path: "ts.csv"}) |> json_response(200)

    status =
      Enum.reduce_while(1..100, nil, fn _, _ ->
        s =
          authed
          |> get("/xrpc/network.bsky.jetstream.getImportStatus?job=#{job}")
          |> json_response(200)

        if s["state"] == "running",
          do:
            (
              Process.sleep(20)
              {:cont, s}
            ),
          else: {:halt, s}
      end)

    assert %{
             "state" => "complete",
             "rowsTotal" => 2,
             "rowsValid" => 1,
             "rowsRejected" => 1,
             "rowsMutated" => 1,
             "bucketed" => true
           } = status

    rows = read_all(target.seq)
    expected = DateTime.to_unix(~U[2022-01-02 03:04:05Z], :microsecond)
    assert Enum.find(rows, &(&1.seq == target.seq)).indexed_at == expected
    assert Enum.find(rows, &(&1.seq == other.seq)).indexed_at == 0

    # a later version of the same record is stamped as it is appended
    {:ok, [again]} =
      Writer.append([%{create("did:plc:ts", 1) | kind: :update, rkey: target.rkey}])

    assert again.indexed_at == expected

    assert authed
           |> get("/xrpc/network.bsky.jetstream.getImportStatus")
           |> json_response(200)
           |> Map.get("job") == job
  end
end
