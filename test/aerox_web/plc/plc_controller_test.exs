defmodule AeroxWeb.PLC.PLCControllerTest do
  @moduledoc "The directory's HTTP surface, driven exactly as did-method-plc's client would."
  use AeroxWeb.ConnCase, async: true
  alias Aerox.ATProto.Crypto
  alias Aerox.PLC.Operations

  @moduletag :service

  setup do
    rotation = Crypto.generate(:k256)

    {genesis, did} =
      Operations.create_op(
        [
          signing_key: Crypto.did_key(rotation),
          handle: "alice.test",
          pds: "https://pds.test",
          rotation_keys: [Crypto.did_key(rotation)]
        ],
        rotation
      )

    {:ok, did: did, genesis: genesis, rotation: rotation}
  end

  test "health", %{conn: conn} do
    assert %{"version" => _} = conn |> get("/_health") |> json_response(200)
  end

  test "browser clients may read the directory (did-method-plc's cors())", %{
    conn: conn,
    did: did,
    genesis: genesis
  } do
    assert conn |> post("/#{did}", genesis) |> response(200) == "OK"
    audit = get(conn, "/#{did}/log/audit")
    assert json_response(audit, 200)
    assert get_resp_header(audit, "access-control-allow-origin") == ["*"]
  end

  test "submit, resolve, log, audit, last, data, export", %{
    conn: conn,
    did: did,
    genesis: genesis,
    rotation: rotation
  } do
    assert conn |> post("/#{did}", genesis) |> response(200) == "OK"

    doc_conn = get(conn, "/#{did}")
    assert response_content_type(doc_conn, :"did+ld+json")
    doc = json_response(doc_conn, 200)
    assert doc["id"] == did
    assert [%{"id" => "#atproto_pds"}] = doc["service"]

    assert %{"did" => ^did, "rotationKeys" => [_]} =
             conn |> get("/#{did}/data") |> json_response(200)

    assert [%{"type" => "plc_operation"}] = conn |> get("/#{did}/log") |> json_response(200)

    assert [%{"nullified" => false, "cid" => _, "createdAt" => _}] =
             conn |> get("/#{did}/log/audit") |> json_response(200)

    assert %{"type" => "plc_operation"} = conn |> get("/#{did}/log/last") |> json_response(200)

    update = Operations.atproto_update_op(genesis, rotation, handle: "alice2.test")
    assert conn |> post("/#{did}", update) |> response(200) == "OK"
    assert %{"alsoKnownAs" => ["at://alice2.test"]} = conn |> get("/#{did}") |> json_response(200)

    # a bad op is 400 with a message, a replay of the genesis is misordered
    assert %{"message" => "Operations not correctly ordered"} =
             conn |> post("/#{did}", genesis) |> json_response(400)

    assert %{"message" => "Not a valid operation" <> _} =
             conn |> post("/#{did}", %{"type" => "plc_operation"}) |> json_response(400)

    export = conn |> get("/export?count=10") |> response(200)
    lines = export |> String.split("\n") |> Enum.map(&Jason.decode!/1)
    assert Enum.any?(lines, &(&1["did"] == did))

    assert %{"message" => "Invalid count parameter"} =
             conn |> get("/export?count=x") |> json_response(400)

    assert %{"message" => "Invalid after parameter"} =
             conn |> get("/export?after=yesterday") |> json_response(400)
  end

  test "unknown and malformed DIDs", %{conn: conn} do
    assert %{"message" => "DID not registered: " <> _} =
             conn |> get("/did:plc:aaaaaaaaaaaaaaaaaaaaaaaa") |> json_response(404)

    assert conn |> get("/did:web:example.com") |> response(404)
  end

  test "admin removeInvalidOps requires the configured secret", %{conn: conn, did: did} do
    assert %{"message" => "admin secret has not been configured"} =
             conn
             |> post("/admin/removeInvalidOps", %{
               "adminSecret" => "x",
               "did" => did,
               "cid" => "b"
             })
             |> json_response(401)
  end
end
