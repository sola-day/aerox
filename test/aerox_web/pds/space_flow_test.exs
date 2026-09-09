defmodule AeroxWeb.PDS.SpaceFlowTest do
  @moduledoc """
  VERIFICATION §6 scenario 9 (Spaces) in-process: an owner creates a
  simplespace and adds a member; the member mints a delegation token (member
  grant) on its PDS role, exchanges it for a DPoP-bound space credential at
  the space host, writes records, and a syncer reads the repo back with the
  credential — LtHash/commit verified, `getRepo` CAR re-imported,
  `listRepoOps` incremental sync, notifications through Oban, deletion,
  policies and OAuth `space:` scope enforcement. Space writes never reach
  `repo_seq`.
  """
  use AeroxWeb.ConnCase, async: false
  use Oban.Testing, repo: Aerox.PDS.Repo, prefix: false

  alias Aerox.ATProto.Space.{LtHash, SignedCommit}
  alias Aerox.PDS.Space.Credentials

  defmodule ClientSite do
    @moduledoc false
    @behaviour Plug
    def init(opts), do: opts

    def call(conn, opts) do
      body =
        case conn.request_path do
          "/client-metadata.json" -> opts[:metadata].()
          "/jwks.json" -> opts[:jwks].()
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end
  end

  alias Aerox.ATProto.Space.Repo, as: KRepo
  alias Aerox.Auth.DPoP
  alias Aerox.PDS.Sequencer
  alias Aerox.PDS.Space.{Notify, Records, Spaces}

  @xrpc "/xrpc/"
  @type_nsid "my.bulletin.board"
  @post "my.bulletin.post"
  @client_id "https://app.example/client-metadata.json"

  setup do
    Aerox.RateLimit.reset()
    owner = signup("space-owner.test")
    member = signup("space-member.test")
    outsider = signup("space-outsider.test")
    {:ok, owner: owner, member: member, outsider: outsider}
  end

  # ------------------------------------------------------------ helpers

  defp signup(handle) do
    {:ok, %{did: did}} =
      Aerox.PDS.Signup.create(%{
        handle: handle,
        email: "#{handle}@example.com",
        password: "correct horse battery staple"
      })

    %{access_jwt: jwt} = Aerox.PDS.Sessions.create_session(did)
    %{did: did, jwt: jwt}
  end

  defp post_xrpc(conn, method, body, auth) do
    conn
    |> with_auth(auth)
    |> put_req_header("content-type", "application/json")
    |> post(@xrpc <> method, Jason.encode!(body))
  end

  defp get_xrpc(conn, method, params, auth \\ nil) do
    conn |> with_auth(auth) |> get(@xrpc <> method, params)
  end

  defp with_auth(conn, nil), do: conn
  defp with_auth(conn, %{jwt: jwt}), do: put_req_header(conn, "authorization", "Bearer " <> jwt)

  defp with_auth(conn, {:bearer, token}),
    do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp with_auth(conn, {:dpop, token, jwk, method, path}) do
    conn
    |> put_req_header("authorization", "DPoP " <> token)
    |> put_req_header("dpop", proof(jwk, method, base() <> path, token))
  end

  defp with_auth(conn, {:oauth, did, scope}) do
    assign(conn, :auth, %{
      type: :oauth,
      did: did,
      scope: :oauth,
      permissions: Aerox.Auth.Scopes.grant(scope),
      token_id: "t",
      client_id: @client_id,
      token: "x"
    })
  end

  defp base, do: Aerox.PDS.Config.public_url()
  defp key, do: JOSE.JWK.generate_key({:ec, "P-256"})
  defp public_map(jwk), do: jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map() |> elem(1)

  defp jwt(jwk, header, claims) do
    {_, token} = JOSE.JWS.sign(jwk, Jason.encode!(claims), header) |> JOSE.JWS.compact()
    token
  end

  defp proof(jwk, method, url, ath \\ nil) do
    claims = %{
      "jti" => Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
      "iat" => System.os_time(:second),
      "htm" => method,
      "htu" => url
    }

    claims = if ath, do: Map.put(claims, "ath", DPoP.ath(ath)), else: claims
    header = %{"alg" => "ES256", "typ" => "dpop+jwt", "jwk" => public_map(jwk)}
    {_, token} = JOSE.JWS.sign(jwk, Jason.encode!(claims), header) |> JOSE.JWS.compact()
    token
  end

  defp payload(jwt) do
    [_, p, _] = String.split(jwt, ".")
    p |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  defp header(jwt) do
    [h, _, _] = String.split(jwt, ".")
    h |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  defp space_uri(owner), do: "at://#{owner.did}/space/#{@type_nsid}/self"

  defp create_space(conn, owner, extra \\ %{}) do
    body =
      Map.merge(
        %{
          "type" => @type_nsid,
          "skey" => "self",
          "policy" => %{"$type" => "com.atproto.simplespace.defs#memberListPolicy"},
          "appAccess" => %{"$type" => "com.atproto.simplespace.defs#open"}
        },
        extra
      )

    conn |> post_xrpc("com.atproto.simplespace.createSpace", body, owner) |> json_response(200)
  end

  # the member's app: delegation token from its PDS role, exchanged at the space host
  defp credential(conn, user, space, jwk, extra \\ %{}) do
    %{"token" => grant} =
      conn
      |> get_xrpc("com.atproto.space.getDelegationToken", %{"space" => space}, user)
      |> json_response(200)

    assert header(grant)["typ"] == "atproto-space-delegation+jwt"
    assert header(grant)["kid"] == "#atproto"
    assert %{"sub" => ^space, "aud" => aud} = payload(grant)
    assert String.ends_with?(aud, "#atproto_space_host")

    conn
    |> then(fn conn ->
      if jwk,
        do:
          put_req_header(
            conn,
            "dpop",
            proof(jwk, "POST", base() <> "/xrpc/com.atproto.space.getSpaceCredential")
          ),
        else: conn
    end)
    |> post_xrpc(
      "com.atproto.space.getSpaceCredential",
      Map.merge(%{"space" => space}, extra),
      {:bearer, grant}
    )
  end

  defp cred_get(conn, method, params, cred, jwk),
    do: get_xrpc(conn, method, params, {:dpop, cred, jwk, "GET", "/xrpc/" <> method})

  defp record(text),
    do: %{"$type" => @post, "text" => text, "createdAt" => "2026-09-09T12:00:00.000Z"}

  defp rkey_of(uri), do: uri |> String.split("/") |> List.last()

  # ------------------------------------------------------------- scenario 9

  test "owner creates a space, member writes, syncer reads with a credential", ctx do
    %{conn: conn, owner: owner, member: member, outsider: outsider} = ctx
    space = space_uri(owner)
    seq_before = Sequencer.current()

    # createSpace in bulletin's shape; the owner is the first member
    assert %{"uri" => ^space} = create_space(conn, owner)

    assert %{"error" => "SpaceAlreadyExists"} =
             conn
             |> post_xrpc(
               "com.atproto.simplespace.createSpace",
               %{"type" => @type_nsid, "skey" => "self"},
               owner
             )
             |> json_response(400)

    assert conn
           |> post_xrpc(
             "com.atproto.simplespace.addMember",
             %{"space" => space, "did" => member.did},
             owner
           )
           |> response(200)

    assert %{"members" => members} =
             conn
             |> get_xrpc("com.atproto.simplespace.listMembers", %{"space" => space}, owner)
             |> json_response(200)

    assert Enum.map(members, & &1["did"]) == Enum.sort([owner.did, member.did])

    # only the owner manages the member list
    assert %{"error" => "NotSpaceOwner"} =
             conn
             |> get_xrpc("com.atproto.simplespace.listMembers", %{"space" => space}, member)
             |> json_response(400)

    # the member list has its own signed commit (scope "members") over the DIDs
    member_commit = Records.signed_commit(owner.did, space, :members)
    expected = Enum.reduce([owner.did, member.did], LtHash.new(), &LtHash.add(&2, &1))
    assert member_commit.hash == LtHash.digest(expected)

    # the space host describes the space (vendored getSpace and the alpha's simplespace.getSpace)
    assert %{
             "uri" => ^space,
             "config" => %{
               "mintPolicy" => "member-list",
               "appAccess" => %{"$type" => "com.atproto.simplespace.defs#open"}
             }
           } =
             conn
             |> get_xrpc("com.atproto.space.getSpace", %{"space" => space}, owner)
             |> json_response(200)

    # member: delegation token → space credential, DPoP-bound
    jwk = key()
    assert %{"credential" => cred} = conn |> credential(member, space, jwk) |> json_response(200)
    assert header(cred)["typ"] == "atproto-space-credential+jwt"
    {:ok, jkt} = DPoP.thumbprint(public_map(jwk))
    assert %{"iss" => owner_did, "sub" => ^space, "cnf" => %{"jkt" => ^jkt}} = payload(cred)
    assert owner_did == owner.did
    refute Map.has_key?(payload(cred), "aud")

    # the exchange needs a DPoP proof (the credential is key-bound) and a fresh token
    assert %{"error" => "InvalidToken"} =
             conn |> credential(member, space, nil) |> json_response(401)

    # a non-member is refused at the space host
    assert %{"error" => "UserNotAuthorized"} =
             conn |> credential(outsider, space, key()) |> json_response(403)

    # the member writes to its own repo in the space (legacy session)
    assert %{"uri" => uri1, "cid" => cid1} =
             conn
             |> post_xrpc(
               "com.atproto.space.createRecord",
               %{
                 "space" => space,
                 "repo" => member.did,
                 "collection" => @post,
                 "record" => record("one")
               },
               member
             )
             |> json_response(200)

    assert String.starts_with?(uri1, "#{space}/#{member.did}/#{@post}/")
    rkey1 = rkey_of(uri1)

    assert %{"uri" => ^uri1, "cid" => cid1b} =
             conn
             |> post_xrpc(
               "com.atproto.space.putRecord",
               %{
                 "space" => space,
                 "repo" => member.did,
                 "collection" => @post,
                 "rkey" => rkey1,
                 "record" => record("one, edited")
               },
               member
             )
             |> json_response(200)

    assert cid1b != cid1

    assert %{"uri" => uri2} =
             conn
             |> post_xrpc(
               "com.atproto.space.createRecord",
               %{
                 "space" => space,
                 "repo" => member.did,
                 "collection" => @post,
                 "rkey" => "second",
                 "record" => record("two")
               },
               member
             )
             |> json_response(200)

    assert %{"error" => "RecordAlreadyExists"} =
             conn
             |> post_xrpc(
               "com.atproto.space.createRecord",
               %{
                 "space" => space,
                 "repo" => member.did,
                 "collection" => @post,
                 "rkey" => "second",
                 "record" => record("two again")
               },
               member
             )
             |> json_response(400)

    assert %{} =
             conn
             |> post_xrpc(
               "com.atproto.space.deleteRecord",
               %{
                 "space" => space,
                 "repo" => member.did,
                 "collection" => @post,
                 "rkey" => rkey_of(uri2)
               },
               member
             )
             |> json_response(200)

    # deleting again succeeds (alpha: "whether or not the record was present")
    assert %{} =
             conn
             |> post_xrpc(
               "com.atproto.space.deleteRecord",
               %{
                 "space" => space,
                 "repo" => member.did,
                 "collection" => @post,
                 "rkey" => "second"
               },
               member
             )
             |> json_response(200)

    # a repo may only be written by its own account
    assert %{"error" => "Forbidden"} =
             conn
             |> post_xrpc(
               "com.atproto.space.createRecord",
               %{
                 "space" => space,
                 "repo" => member.did,
                 "collection" => @post,
                 "record" => record("x")
               },
               outsider
             )
             |> json_response(403)

    # applyWrites: a batch under one rev
    assert %{
             "results" => [
               %{"$type" => "com.atproto.space.applyWrites#createResult", "uri" => uri3},
               %{"$type" => "com.atproto.space.applyWrites#deleteResult"}
             ]
           } =
             conn
             |> post_xrpc(
               "com.atproto.space.applyWrites",
               %{
                 "space" => space,
                 "repo" => member.did,
                 "writes" => [
                   %{
                     "$type" => "com.atproto.space.applyWrites#create",
                     "collection" => @post,
                     "rkey" => "third",
                     "value" => record("three")
                   },
                   %{
                     "$type" => "com.atproto.space.applyWrites#delete",
                     "collection" => @post,
                     "rkey" => "third"
                   }
                 ]
               },
               member
             )
             |> json_response(200)

    assert rkey_of(uri3) == "third"

    # DESIGN §12.3: nothing reached the sequencer
    assert Sequencer.current() == seq_before

    # the member's PDS lists the space it wrote to; the owner's lists the one it owns
    assert %{"spaces" => [%{"uri" => ^space, "isOwner" => false}]} =
             conn |> get_xrpc("com.atproto.space.listSpaces", %{}, member) |> json_response(200)

    assert %{"spaces" => [%{"uri" => ^space, "isOwner" => true}]} =
             conn
             |> get_xrpc(
               "com.atproto.space.listSpaces",
               %{"did" => owner.did, "type" => @type_nsid},
               owner
             )
             |> json_response(200)

    # the syncer reads the member's repo with the credential (DPoP + proof with ath)
    assert %{"records" => [%{"collection" => @post, "rkey" => ^rkey1, "cid" => ^cid1b}]} =
             conn
             |> cred_get(
               "com.atproto.space.listRecords",
               %{"space" => space, "repo" => member.did},
               cred,
               jwk
             )
             |> json_response(200)

    assert %{"uri" => ^uri1, "cid" => ^cid1b, "value" => %{"text" => "one, edited"}} =
             conn
             |> cred_get(
               "com.atproto.space.getRecord",
               %{"space" => space, "repo" => member.did, "collection" => @post, "rkey" => rkey1},
               cred,
               jwk
             )
             |> json_response(200)

    # a credential is always key-bound: presenting it without its proof fails,
    # and a proof by another key fails
    assert %{"error" => "InvalidCredential"} =
             conn
             |> get_xrpc(
               "com.atproto.space.listRecords",
               %{"space" => space, "repo" => member.did},
               {:bearer, cred}
             )
             |> json_response(401)

    assert %{"error" => "InvalidCredential"} =
             conn
             |> cred_get(
               "com.atproto.space.listRecords",
               %{"space" => space, "repo" => member.did},
               cred,
               key()
             )
             |> json_response(401)

    other_space = "at://#{owner.did}/space/#{@type_nsid}/other"

    assert %{"error" => "InvalidRequest", "message" => "Credential space mismatch"} =
             conn
             |> get_xrpc(
               "com.atproto.space.listRecords",
               %{"space" => other_space, "repo" => member.did},
               {:dpop, cred, jwk, "GET", "/xrpc/com.atproto.space.listRecords"}
             )
             |> json_response(400)

    # no credential, no session: refused
    assert %{"error" => "AuthMissing"} =
             conn
             |> get_xrpc("com.atproto.space.getRecord", %{
               "space" => space,
               "repo" => member.did,
               "collection" => @post,
               "rkey" => rkey1
             })
             |> json_response(401)

    # the signed commit: hash = LtHash digest of the records, MAC bound to the
    # space context, signature under the writer's key (deniable, over ikm)
    assert %{"commit" => commit_lex} =
             conn
             |> cred_get(
               "com.atproto.space.getRepoState",
               %{"space" => space, "repo" => member.did},
               cred,
               jwk
             )
             |> json_response(200)

    assert commit_lex["ver"] == 1
    commit = SignedCommit.from_lex(commit_lex)
    {:ok, value} = Records.get_record(member.did, space, @post, rkey1)

    recomputed =
      KRepo.recompute(%{
        KRepo.key(@post, rkey1) => {Aerox.ATProto.CID.parse!(cid1b), value.value}
      })

    assert commit.hash == LtHash.digest(recomputed.set_hash)
    {:ok, parsed} = Aerox.PDS.Space.Uri.parse(space)
    {:ok, member_key} = Aerox.Identity.resolve_signing_key(Aerox.PDS.Identity, member.did, [])

    assert SignedCommit.verify(
             commit,
             Records.context(parsed, member.did, commit.rev),
             member_key
           )

    refute SignedCommit.verify(commit, Records.context(parsed, owner.did, commit.rev), member_key)
    {:ok, owner_key} = Aerox.Identity.resolve_signing_key(Aerox.PDS.Identity, owner.did, [])
    refute SignedCommit.verify(commit, Records.context(parsed, member.did, commit.rev), owner_key)

    # listRepoOps: the whole log with the commit at the head; incremental since a rev; paged
    assert %{"ops" => ops, "commit" => %{"rev" => head_rev}} =
             conn
             |> cred_get(
               "com.atproto.space.listRepoOps",
               %{"space" => space, "repo" => member.did},
               cred,
               jwk
             )
             |> json_response(200)

    assert head_rev == commit.rev
    assert length(ops) == 6
    # the superseded first value is not inlined; the current one is
    assert %{"cid" => ^cid1, "prev" => nil} = hd(ops)
    refute Map.has_key?(hd(ops), "value")

    assert %{"cid" => ^cid1b, "prev" => ^cid1, "value" => %{"text" => "one, edited"}} =
             Enum.at(ops, 1)

    assert %{"cid" => nil, "collection" => @post, "rkey" => "second"} = Enum.at(ops, 3)
    first_rev = hd(ops)["rev"]

    assert %{"ops" => later, "commit" => _} =
             conn
             |> cred_get(
               "com.atproto.space.listRepoOps",
               %{"space" => space, "repo" => member.did, "since" => first_rev},
               cred,
               jwk
             )
             |> json_response(200)

    assert length(later) == 5
    refute Enum.any?(later, &(&1["rev"] == first_rev))

    page =
      conn
      |> cred_get(
        "com.atproto.space.listRepoOps",
        %{"space" => space, "repo" => member.did, "limit" => "2"},
        cred,
        jwk
      )
      |> json_response(200)

    assert length(page["ops"]) == 2
    refute Map.has_key?(page, "commit")
    assert cursor = page["cursor"]

    page2 =
      conn
      |> cred_get(
        "com.atproto.space.listRepoOps",
        %{"space" => space, "repo" => member.did, "limit" => "10", "cursor" => cursor},
        cred,
        jwk
      )
      |> json_response(200)

    assert length(page2["ops"]) == 4
    assert page2["commit"]["rev"] == commit.rev

    # getRepo: the two-root CAR imports back to the same state
    car =
      conn
      |> cred_get(
        "com.atproto.space.getRepo",
        %{"space" => space, "repo" => member.did},
        cred,
        jwk
      )
      |> response(200)

    assert {:ok, car_commit, state} = KRepo.import_car(car)
    assert car_commit.hash == commit.hash
    assert Map.keys(state.records) == [KRepo.key(@post, rkey1)]

    assert SignedCommit.verify(
             car_commit,
             Records.context(parsed, member.did, car_commit.rev),
             member_key
           )

    # notifications: every write queued a notifyWrite to the space host
    assert_enqueued(
      worker: Notify.NotifyWrite,
      args: %{"space" => space, "repo" => member.did, "rev" => commit.rev}
    )

    # the syncer registers for the space's writes at the space host
    assert %{"expiresAt" => _} =
             conn
             |> post_xrpc(
               "com.atproto.space.registerNotify",
               %{"space" => space, "endpoint" => "https://syncer.example/notify"},
               {:dpop, cred, jwk, "POST", "/xrpc/com.atproto.space.registerNotify"}
             )
             |> json_response(200)

    # deliver: the writer's PDS notifies the space host (our own endpoint), which
    # records the writer for listRepos and fans out to the registered syncer
    assert %{success: n} = Oban.drain_queue(Aerox.PDS.Oban, queue: :spaces, with_recursion: false)
    assert n >= 1

    assert %{
             "repos" => [
               %{"did" => member_did, "rev" => ^head_rev, "hash" => %{"$bytes" => hash_b64}}
             ]
           } =
             conn
             |> cred_get("com.atproto.space.listRepos", %{"space" => space}, cred, jwk)
             |> json_response(200)

    assert member_did == member.did
    assert Base.decode64!(hash_b64, padding: false) == commit.hash

    assert_enqueued(
      worker: Notify.FanOut,
      args: %{"owner" => owner.did, "space" => space, "repo" => member.did}
    )

    assert %{success: n2} =
             Oban.drain_queue(Aerox.PDS.Oban, queue: :spaces, with_recursion: false)

    assert n2 >= 1

    assert_enqueued(
      worker: Notify.Deliver,
      args: %{
        "url" => "https://syncer.example/notify/xrpc/com.atproto.space.notifyWrite",
        "lxm" => "com.atproto.space.notifyWrite",
        "iss" => owner.did
      }
    )

    # notifyWrite must be signed by the writer it claims
    forged =
      Aerox.Auth.ServiceJWT.create(
        keypair: Aerox.PDS.Accounts.signing_keypair(outsider.did),
        iss: outsider.did,
        aud: owner.did,
        lxm: "com.atproto.space.notifyWrite"
      )

    assert %{"error" => "Forbidden"} =
             conn
             |> post_xrpc(
               "com.atproto.space.notifyWrite",
               %{"space" => space, "repo" => member.did, "rev" => head_rev},
               {:bearer, forged}
             )
             |> json_response(403)

    # deleteSpace: tombstoned at the host, members' PDSes told (through Oban), reads refused
    assert conn
           |> post_xrpc("com.atproto.simplespace.deleteSpace", %{"space" => space}, owner)
           |> response(200)

    assert_enqueued(
      worker: Notify.Deliver,
      args: %{"aud" => member.did, "lxm" => "com.atproto.space.notifySpaceDeleted"}
    )

    assert_enqueued(
      worker: Notify.Deliver,
      args: %{"url" => "https://syncer.example/notify/xrpc/com.atproto.space.notifySpaceDeleted"}
    )

    Oban.drain_queue(Aerox.PDS.Oban, queue: :spaces, with_recursion: false)
    assert %{deleted_at: %DateTime{}} = Spaces.get(member.did, space)

    assert %{"error" => "SpaceNotFound"} =
             conn
             |> get_xrpc(
               "com.atproto.space.getRecord",
               %{"space" => space, "repo" => member.did, "collection" => @post, "rkey" => rkey1},
               member
             )
             |> json_response(400)

    assert %{"error" => "SpaceDeleted"} =
             conn |> credential(member, space, key()) |> json_response(400)
  end

  test "policies: public admits anyone, app allow-list gates on the attested client", ctx do
    %{conn: conn, owner: owner, outsider: outsider, member: member} = ctx
    space = space_uri(owner)

    assert %{"uri" => ^space} =
             create_space(conn, owner, %{
               "policy" => %{"$type" => "com.atproto.simplespace.defs#publicPolicy"}
             })

    assert %{
             "policy" => %{"$type" => "com.atproto.simplespace.defs#publicPolicy"},
             "appAccess" => %{"$type" => "com.atproto.simplespace.defs#open"}
           } =
             conn
             |> get_xrpc("com.atproto.simplespace.getSpace", %{"space" => space}, owner)
             |> json_response(200)

    assert %{"credential" => _} = conn |> credential(outsider, space, key()) |> json_response(200)

    # updateSpace: allow-list one client; from now on the app must attest its identity
    assert conn
           |> post_xrpc(
             "com.atproto.simplespace.updateSpace",
             %{
               "space" => space,
               "appAccess" => %{
                 "$type" => "com.atproto.simplespace.defs#allowList",
                 "allowed" => [@client_id]
               }
             },
             owner
           )
           |> response(200)

    assert %{"error" => "AppNotAuthorized"} =
             conn |> credential(outsider, space, key()) |> json_response(403)

    # the client publishes its key in its OAuth metadata (jwks_uri); the
    # attestation is signed with it, addressed to this space host
    client_key = key()
    {_, client_public} = client_key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    client_public = Map.put(client_public, "kid", "k1")

    metadata = fn ->
      %{
        "client_id" => @client_id,
        "client_name" => "Bulletin",
        "redirect_uris" => ["https://app.example/callback"],
        "scope" => "atproto",
        "grant_types" => ["authorization_code", "refresh_token"],
        "response_types" => ["code"],
        "application_type" => "web",
        "token_endpoint_auth_method" => "private_key_jwt",
        "token_endpoint_auth_signing_alg" => "ES256",
        "jwks_uri" => "https://app.example/jwks.json",
        "dpop_bound_access_tokens" => true
      }
    end

    Application.put_env(:aerox, Aerox.PDS.OAuth.Clients,
      plug: {ClientSite, [metadata: metadata, jwks: fn -> %{"keys" => [client_public]} end]}
    )

    on_exit(fn -> Application.delete_env(:aerox, Aerox.PDS.OAuth.Clients) end)
    Aerox.PDS.OAuth.Clients.flush_cache()

    attestation = fn jwk, aud ->
      now = System.os_time(:second)

      jwt(jwk, %{"alg" => "ES256", "typ" => "atproto-client-attestation+jwt", "kid" => "k1"}, %{
        "iss" => @client_id,
        "sub" => @client_id,
        "aud" => aud,
        "iat" => now,
        "exp" => now + 60,
        "jti" => Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
      })
    end

    good = %{
      "clientAttestation" => attestation.(client_key, Credentials.space_host_aud(owner.did))
    }

    assert %{"credential" => _} =
             conn |> credential(member, space, key(), good) |> json_response(200)

    # an attestation by an unpublished key, or for another space host, is refused
    forged = %{"clientAttestation" => attestation.(key(), Credentials.space_host_aud(owner.did))}

    assert %{"error" => "InvalidClientAttestation"} =
             conn |> credential(member, space, key(), forged) |> json_response(400)

    misaddressed = %{
      "clientAttestation" => attestation.(client_key, "did:web:other#atproto_space_host")
    }

    assert %{"error" => "InvalidClientAttestation"} =
             conn |> credential(member, space, key(), misaddressed) |> json_response(400)

    # back to member-list: the outsider is refused on the user perimeter first
    assert conn
           |> post_xrpc(
             "com.atproto.simplespace.updateSpace",
             %{"space" => space, "mintPolicy" => "member-list"},
             owner
           )
           |> response(200)

    assert %{"error" => "UserNotAuthorized"} =
             conn |> credential(outsider, space, key(), good) |> json_response(403)

    assert conn
           |> post_xrpc(
             "com.atproto.simplespace.addMember",
             %{"space" => space, "did" => outsider.did},
             owner
           )
           |> response(200)

    assert %{"credential" => _} =
             conn |> credential(outsider, space, key(), good) |> json_response(200)

    assert %{"error" => "AppNotAuthorized"} =
             conn |> credential(outsider, space, key()) |> json_response(403)
  end

  test "OAuth space: scopes are enforced (upstream assertSpaceScope)", ctx do
    %{conn: conn, owner: owner, member: member} = ctx
    space = space_uri(owner)
    assert %{"uri" => ^space} = create_space(conn, owner)

    scoped =
      {:oauth, member.did,
       "atproto space:#{@type_nsid}?authority=#{owner.did}&skey=self&collection=#{@post}&action=create"}

    body = %{
      "space" => space,
      "repo" => member.did,
      "collection" => @post,
      "rkey" => "a",
      "record" => record("scoped")
    }

    assert %{"uri" => _} =
             conn
             |> post_xrpc("com.atproto.space.createRecord", body, scoped)
             |> json_response(200)

    assert %{"error" => "InvalidToken"} =
             conn
             |> post_xrpc(
               "com.atproto.space.deleteRecord",
               Map.take(body, ["space", "repo", "collection", "rkey"]),
               scoped
             )
             |> json_response(403)

    assert %{"error" => "InvalidToken"} =
             conn
             |> post_xrpc(
               "com.atproto.space.createRecord",
               Map.put(body, "collection", "my.bulletin.removal"),
               scoped
             )
             |> json_response(403)

    # listSpaces asserts read on (type, did, skey "*"): a scope narrower than
    # space:* needs the type/did filters, and a single-skey scope never qualifies
    assert %{"error" => "InvalidToken"} =
             conn |> get_xrpc("com.atproto.space.listSpaces", %{}, scoped) |> json_response(403)

    list_scope =
      {:oauth, member.did, "atproto space:#{@type_nsid}?authority=#{owner.did}&action=read"}

    assert %{"error" => "InvalidToken"} =
             conn
             |> get_xrpc("com.atproto.space.listSpaces", %{}, list_scope)
             |> json_response(403)

    assert %{"spaces" => [_]} =
             conn
             |> get_xrpc(
               "com.atproto.space.listSpaces",
               %{"type" => @type_nsid, "did" => owner.did},
               list_scope
             )
             |> json_response(200)

    # managing the member list is `manage=update`
    manage =
      {:oauth, owner.did,
       "atproto space:#{@type_nsid}?authority=#{owner.did}&skey=self&action=read_self&manage=update"}

    read_only =
      {:oauth, owner.did,
       "atproto space:#{@type_nsid}?authority=#{owner.did}&skey=self&action=read"}

    assert conn
           |> post_xrpc(
             "com.atproto.simplespace.addMember",
             %{"space" => space, "did" => member.did},
             manage
           )
           |> response(200)

    assert %{"error" => "InvalidToken"} =
             conn
             |> post_xrpc(
               "com.atproto.simplespace.addMember",
               %{"space" => space, "did" => member.did},
               read_only
             )
             |> json_response(403)

    assert %{"error" => "InvalidToken"} =
             conn
             |> post_xrpc(
               "com.atproto.simplespace.createSpace",
               %{"type" => @type_nsid, "skey" => "two"},
               read_only
             )
             |> json_response(403)
  end

  test "the feature flag answers 501 when Spaces is disabled", %{conn: conn, owner: owner} do
    cfg = Application.get_env(:aerox, Aerox.PDS.Space)
    Application.put_env(:aerox, Aerox.PDS.Space, Keyword.put(cfg, :enabled, false))
    on_exit(fn -> Application.put_env(:aerox, Aerox.PDS.Space, cfg) end)

    assert %{"error" => "MethodNotImplemented"} =
             conn |> get_xrpc("com.atproto.space.listSpaces", %{}, owner) |> json_response(501)
  end
end
