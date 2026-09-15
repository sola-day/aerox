defmodule AeroxWeb.PDS.LexiconResolutionTest do
  @moduledoc """
  Lexicon spec, "Lexicon Publication and Resolution", and the Permission spec's
  dynamically resolved permission sets: `_lexicon` DNS → DID → a verified
  `sync.getRecord` proof → a lexicon document; `resolveLexicon`; the PDS cache
  that serves the last good document when a refresh fails; token scopes that
  expand a resolved permission set.
  """
  use AeroxWeb.ConnCase, async: false
  import Mox
  alias Aerox.Identity.LexiconResolver
  alias Aerox.PDS.Lexicons

  @nsid "com.example.lexres.authBasic"

  setup :set_mox_global

  setup %{conn: conn} do
    Aerox.RateLimit.reset()
    dns = Application.get_env(:aerox, Aerox.Identity.DNS)
    Application.put_env(:aerox, Aerox.Identity.DNS, Aerox.Identity.DNSMock)

    on_exit(fn ->
      if dns,
        do: Application.put_env(:aerox, Aerox.Identity.DNS, dns),
        else: Application.delete_env(:aerox, Aerox.Identity.DNS)
    end)

    {:ok, author} =
      Aerox.PDS.Signup.create(%{
        handle: "lexauthor.test",
        email: "lex@example.com",
        password: "pw-pw-pw-pw"
      })

    publish!(author.did, @nsid, %{
      "type" => "permission-set",
      "title" => "Basic lexres",
      "detail" => "Write lexres posts",
      "permissions" => [
        %{
          "type" => "permission",
          "resource" => "repo",
          "collection" => ["com.example.lexres.post"]
        }
      ]
    })

    {:ok, conn: %{conn | host: "pds.aerox.sola.town"}, author: author}
  end

  defp publish!(did, nsid, main) do
    {:ok, w} =
      Aerox.PDS.Records.Prepare.create(
        did,
        "com.atproto.lexicon.schema",
        %{
          "$type" => "com.atproto.lexicon.schema",
          "lexicon" => 1,
          "id" => nsid,
          "defs" => %{"main" => main}
        },
        rkey: nsid
      )

    {:ok, _} = Aerox.PDS.Records.process_writes(did, [w])
  end

  defp dns_points_at(did) do
    stub(Aerox.Identity.DNSMock, :txt, fn
      "_lexicon.lexres.example.com", _ -> {:ok, ["v=spf1 nothing", "did=" <> did]}
      _, _ -> {:error, :nxdomain}
    end)
  end

  test "resolution: DNS names the authority, the record proof is verified", %{author: author} do
    dns_points_at(author.did)
    opts = [plc_url: Aerox.PDS.Config.plc_url()]

    assert {:ok, %{uri: uri, cid: "bafyrei" <> _, did: did, record: record}} =
             LexiconResolver.resolve(@nsid, opts)

    assert did == author.did
    assert uri == "at://#{author.did}/com.atproto.lexicon.schema/#{@nsid}"
    assert record["defs"]["main"]["title"] == "Basic lexres"

    # resolution is not hierarchical: a sibling authority has no record
    assert {:error, :no_did_authority} =
             LexiconResolver.resolve("com.example.other.authBasic", opts)

    # the authority's repo has no such lexicon
    assert {:error, _} = LexiconResolver.resolve("com.example.lexres.authMissing", opts)

    assert LexiconResolver.dns_name("edu.university.dept.lab.blogging.getBlogPost") ==
             "_lexicon.blogging.lab.dept.university.edu"

    # a record whose id is not the NSID is refused
    publish!(author.did, "com.example.lexres.authWrongId", %{
      "type" => "permission-set",
      "permissions" => []
    })

    {:ok, w} =
      Aerox.PDS.Records.Prepare.update(
        author.did,
        "com.atproto.lexicon.schema",
        "com.example.lexres.authWrongId",
        %{
          "$type" => "com.atproto.lexicon.schema",
          "lexicon" => 1,
          "id" => "com.example.lexres.authSomethingElse",
          "defs" => %{"main" => %{"type" => "permission-set", "permissions" => []}}
        }
      )

    {:ok, _} = Aerox.PDS.Records.process_writes(author.did, [w])

    assert {:error, {:id_mismatch, _}} =
             LexiconResolver.resolve("com.example.lexres.authWrongId", opts)
  end

  test "resolveLexicon, the cache, and the last good document on failure", %{
    conn: conn,
    author: author
  } do
    dns_points_at(author.did)

    body =
      conn |> get("/xrpc/com.atproto.lexicon.resolveLexicon?nsid=#{@nsid}") |> json_response(200)

    assert body["uri"] == "at://#{author.did}/com.atproto.lexicon.schema/#{@nsid}"
    assert body["schema"]["$type"] == "com.atproto.lexicon.schema"
    assert body["schema"]["defs"]["main"]["type"] == "permission-set"

    assert %{"error" => "LexiconNotFound"} =
             conn
             |> get("/xrpc/com.atproto.lexicon.resolveLexicon?nsid=com.example.nowhere.thing")
             |> json_response(400)

    # DNS goes away: a forced refresh fails, the last good document stays
    stub(Aerox.Identity.DNSMock, :txt, fn _, _ -> {:error, :nxdomain} end)
    assert {:ok, %{doc: %{"id" => @nsid}}} = Lexicons.get(@nsid, force: true)
    assert %{"title" => "Basic lexres"} = Lexicons.permission_set(@nsid)

    # a vendored permission set needs no network at all
    assert %{"type" => "permission-set"} = Lexicons.permission_set("app.bsky.authCreatePosts")
    assert Lexicons.permission_set("com.example.nowhere.thing") == nil
  end

  test "a token scope expands a resolved permission set", %{author: author} do
    dns_points_at(author.did)

    scope =
      Aerox.Auth.Scopes.build_token_scope(
        "atproto include:#{@nsid}",
        author.did,
        &Lexicons.permission_set/1
      )

    assert "atproto" in String.split(scope)

    assert Enum.any?(
             String.split(scope),
             &String.starts_with?(&1, "repo:com.example.lexres.post")
           )

    # a permission set may only grant within its own authority
    publish!(author.did, "com.example.lexres.authGreedy", %{
      "type" => "permission-set",
      "permissions" => [
        %{"type" => "permission", "resource" => "repo", "collection" => ["app.bsky.feed.post"]}
      ]
    })

    greedy =
      Aerox.Auth.Scopes.build_token_scope(
        "atproto include:com.example.lexres.authGreedy",
        author.did,
        &Lexicons.permission_set/1
      )

    assert greedy == "atproto"
  end
end
