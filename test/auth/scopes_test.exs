defmodule Aerox.Auth.ScopesTest do
  @moduledoc """
  Vectors transcribed from upstream `@atproto/oauth-scopes` tests
  (`scopes/*.test.ts`, `scope-permissions-transition.test.ts` at atproto
  @62f944dd) and the permissioned-data branch's `space-permission.ts`.
  """
  use ExUnit.Case, async: true
  alias Aerox.Auth.Scopes

  describe "repo" do
    test "positional, actions, wildcard, defaults" do
      assert {:repo, %{collection: ["com.example.foo"], action: ["create", "update", "delete"]}} =
               Scopes.parse("repo:com.example.foo")

      assert {:repo, %{collection: ["com.example.foo"], action: ["create", "update"]}} =
               Scopes.parse("repo:com.example.foo?action=create&action=update")

      assert {:repo, %{collection: ["*"], action: ["create"]}} =
               Scopes.parse("repo:*?action=create")

      assert {:repo, %{collection: ["*"], action: ["create", "update", "delete"]}} =
               Scopes.parse("repo:*")

      assert Scopes.matches?("repo:*", :repo, %{collection: "com.example.foo", action: "delete"})

      refute Scopes.matches?("repo:*?action=create", :repo, %{
               collection: "com.example.foo",
               action: "delete"
             })

      assert nil == Scopes.parse("repo:foo bar")
      assert nil == Scopes.parse("repo:.foo")
      assert nil == Scopes.parse("repo:bar.")
      assert nil == Scopes.parse("repo:com.example.foo?action=invalid")
      assert nil == Scopes.parse("invalid")
      assert nil == Scopes.parse("scope")
      # the same collection in positional and query form is rejected
      assert nil == Scopes.parse("repo:com.example.foo?collection=com.example.bar")
      # canonical formatting
      assert "repo:com.example.foo" ==
               Scopes.format(
                 Scopes.parse("repo:com.example.foo?action=create&action=update&action=delete")
               )

      assert "repo?collection=com.example.a&collection=com.example.b" ==
               Scopes.format(
                 Scopes.parse("repo?collection=com.example.b&collection=com.example.a")
               )
    end
  end

  describe "rpc" do
    test "aud is required, lxm positional or query, no double wildcard" do
      assert {:rpc, %{lxm: ["com.example.service"], aud: "did:web:example.com#service_id"}} =
               Scopes.parse("rpc:com.example.service?aud=did:web:example.com%23service_id")

      assert {:rpc, %{lxm: ["com.example.method1"], aud: "*"}} =
               Scopes.parse("rpc?lxm=com.example.method1&aud=*")

      assert {:rpc, %{lxm: ["com.example.method1"], aud: "*"}} =
               Scopes.parse("rpc:com.example.method1?aud=*")

      assert nil == Scopes.parse("rpc?aud=did:web:example.com%23service_id")
      assert nil == Scopes.parse("rpc?lxm=com.example.method1")
      assert nil == Scopes.parse("rpc:com.example.method1")

      assert nil ==
               Scopes.parse(
                 "rpc:com.example.method1?aud=did:web:example.com&lxm=com.example.method2"
               )

      assert {:rpc, %{lxm: ["com.example.method1", "com.example.method2"]}} =
               Scopes.parse("rpc?aud=*&lxm=com.example.method1&lxm=com.example.method2")

      assert nil == Scopes.parse("rpc?aud=*&lxm=*")
      assert nil == Scopes.parse("rpc:*?aud=*")
      assert nil == Scopes.parse("rpc:com.example.service?aud=invalid")
      assert nil == Scopes.parse("rpc:invalid")

      assert Scopes.matches?("rpc:*?aud=did:web:x.com", :rpc, %{
               lxm: "com.example.m",
               aud: "did:web:x.com"
             })

      refute Scopes.matches?("rpc:*?aud=did:web:x.com", :rpc, %{
               lxm: "com.example.m",
               aud: "did:web:y.com"
             })

      assert "rpc:com.example.foo?aud=did:web:example.com%23my_service" ==
               Scopes.format(
                 {:rpc, %{lxm: ["com.example.foo"], aud: "did:web:example.com#my_service"}}
               )
    end
  end

  describe "blob, account, identity" do
    test "parse and match" do
      assert {:blob, %{accept: ["*/*"]}} = Scopes.parse("blob:*/*")
      assert {:blob, %{accept: ["*/*"]}} = Scopes.parse("blob?accept=image/png&accept=*/*")
      assert Scopes.matches?("blob:image/*", :blob, %{mime: "image/png"})
      refute Scopes.matches?("blob:image/*", :blob, %{mime: "video/mp4"})
      assert {:account, %{attr: "email", action: ["read"]}} = Scopes.parse("account:email")

      assert {:account, %{attr: "email", action: ["read", "manage"]}} =
               Scopes.parse("account:email?action=manage&action=read")

      assert Scopes.matches?("account:email?action=manage", :account, %{
               attr: "email",
               action: "read"
             })

      refute Scopes.matches?("account:email", :account, %{attr: "email", action: "manage"})
      assert nil == Scopes.parse("account:nope")
      assert {:identity, %{attr: "handle"}} = Scopes.parse("identity:handle")
      assert Scopes.matches?("identity:*", :identity, %{attr: "handle"})
      assert nil == Scopes.parse("identity:email")
      assert "account:email" == Scopes.format(Scopes.parse("account:email?action=read"))
    end
  end

  describe "space (permissioned data, published alpha grammar)" do
    test "grammar and matching" do
      assert {:space,
              %{
                type: "com.example.space",
                authority: "self",
                skey: "*",
                collection: [],
                action: ["read", "create", "update", "delete"],
                manage: []
              }} = Scopes.parse("space:com.example.space")

      s =
        "space:com.example.space?authority=did:plc:aaaaaaaaaaaaaaaaaaaaaaaa&skey=abc&collection=com.example.note&action=read&action=create&manage=update"

      assert {:space,
              %{
                authority: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa",
                skey: "abc",
                collection: ["com.example.note"],
                action: ["read", "create"],
                manage: ["update"]
              }} = Scopes.parse(s)

      t = %{type: "com.example.space", authority: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa", skey: "abc"}
      assert Scopes.matches?(s, :space, Map.put(t, :action, "read"))
      assert Scopes.matches?(s, :space, Map.put(t, :action, "read_self"))

      assert Scopes.matches?(
               s,
               :space,
               Map.merge(t, %{action: "create", collection: "com.example.note"})
             )

      refute Scopes.matches?(
               s,
               :space,
               Map.merge(t, %{action: "create", collection: "com.example.other"})
             )

      assert Scopes.matches?(s, :space, Map.put(t, :manage, "update"))
      refute Scopes.matches?(s, :space, Map.put(t, :manage, "delete"))
      # an unresolved `self` authority matches nothing
      refute Scopes.matches?("space:com.example.space", :space, Map.put(t, :action, "read"))
      assert nil == Scopes.parse("space:com.example.space?authority=nope")

      assert "space:com.example.space?authority=did:plc:aaaaaaaaaaaaaaaaaaaaaaaa&skey=abc&action=read_self&manage=delete" ==
               Scopes.needed_for(:space, Map.put(t, :manage, "delete"))
    end

    test "issuance-time resolution: self → user, default collections from the space type" do
      perms = Scopes.grant("atproto space:my.bulletin.board?skey=self").permissions

      assert [{:atproto, nil}, {:space, %{authority: "did:plc:user", collection: cols}}] =
               Scopes.resolve_space(perms, "did:plc:user")

      assert cols == ["my.bulletin.post", "my.bulletin.removal", "my.bulletin.position"]
    end

    test "build_token_scope materialises include: into granular scopes for the token" do
      scope =
        Scopes.build_token_scope(
          "atproto blob?accept=image/png include:my.bulletin.permissions",
          "did:plc:user"
        )

      assert scope =~
               ~r/^atproto blob\?accept=image\/png space:my\.bulletin\.board\?authority=\*&skey=self/

      assert scope =~ "manage=create&manage=update&manage=delete"

      assert scope =~
               "collection=my.bulletin.position&collection=my.bulletin.post&collection=my.bulletin.removal"

      refute scope =~ "include:"
      # no include: → unchanged
      assert "atproto repo:app.bsky.feed.post" ==
               Scopes.build_token_scope("atproto repo:app.bsky.feed.post", "did:plc:user")
    end

    test "include: expands bulletin's permission set into a space permission" do
      %{permissions: perms} = Scopes.grant("atproto include:my.bulletin.permissions")

      assert [{:space, p}] = Enum.filter(perms, &match?({:space, _}, &1))
      assert p.type == "my.bulletin.board" and p.authority == "*" and p.skey == "self"
      assert p.manage == ["create", "update", "delete"]
      assert "my.bulletin.post" in p.collection
    end
  end

  describe "include" do
    test "parse, format, parent authority" do
      assert {:include, %{nsid: "com.example.bar", aud: nil}} =
               Scopes.parse("include:com.example.bar")

      assert {:include, %{nsid: "com.example.baz", aud: nil}} =
               Scopes.parse("include?nsid=com.example.baz")

      assert "include:com.example.foo" ==
               Scopes.format({:include, %{nsid: "com.example.foo", aud: nil}})

      assert "include:com.example.foo?aud=did:web:example.com%23my_service" ==
               Scopes.format(
                 {:include, %{nsid: "com.example.foo", aud: "did:web:example.com#my_service"}}
               )

      lex = "com.example.foo.auth"
      assert Scopes.parent_authority?(lex, "com.example.foo.identifier")
      assert Scopes.parent_authority?(lex, "com.example.foo.bar.baz")
      assert Scopes.parent_authority?(lex, "com.example.foo.bar.baz.quz")
      refute Scopes.parent_authority?(lex, "com")
      refute Scopes.parent_authority?(lex, "com.example")
      refute Scopes.parent_authority?(lex, "com.example.bar")
      refute Scopes.parent_authority?(lex, "com.example.bar.foo")
      refute Scopes.parent_authority?(lex, "com.atproto.foo")
      refute Scopes.parent_authority?(lex, "com.atproto.foo.auth")
      refute Scopes.parent_authority?(lex, "*")
    end

    test "expansion: blob rejected, rpc with * aud, inherited aud, repo" do
      inc = %{nsid: "com.example.calendar.auth", aud: nil}

      blob = %{
        "type" => "permission-set",
        "permissions" => [
          %{"type" => "permission", "resource" => "blob", "accept" => ["image/*"]}
        ]
      }

      assert [] == Scopes.expand_include(inc, blob)

      rpc = %{
        "type" => "permission-set",
        "permissions" => [
          %{
            "type" => "permission",
            "resource" => "rpc",
            "aud" => "*",
            "lxm" => ["com.example.calendar.listEvents"]
          }
        ]
      }

      assert ["rpc:com.example.calendar.listEvents?aud=*"] ==
               Enum.map(Scopes.expand_include(inc, rpc), &Scopes.format/1)

      inherit = %{
        "type" => "permission-set",
        "permissions" => [
          %{
            "type" => "permission",
            "resource" => "rpc",
            "inheritAud" => true,
            "lxm" => ["com.example.calendar.listEvents"]
          },
          %{
            "type" => "permission",
            "resource" => "rpc",
            "inheritAud" => true,
            "lxm" => ["com.example.calendar.getEventDetails"]
          }
        ]
      }

      assert [
               "rpc:com.example.calendar.listEvents?aud=did:web:example.com%23foo",
               "rpc:com.example.calendar.getEventDetails?aud=did:web:example.com%23foo"
             ] ==
               Enum.map(
                 Scopes.expand_include(%{inc | aud: "did:web:example.com#foo"}, inherit),
                 &Scopes.format/1
               )

      # without an aud to inherit, inheritAud permissions are dropped
      assert [] == Scopes.expand_include(inc, inherit)

      repo = %{
        "type" => "permission-set",
        "permissions" => [
          %{
            "type" => "permission",
            "resource" => "repo",
            "collection" => ["com.example.calendar.event"]
          }
        ]
      }

      assert ["repo:com.example.calendar.event"] ==
               Enum.map(Scopes.expand_include(inc, repo), &Scopes.format/1)

      # a collection outside the lexicon's authority is refused
      other = %{
        "type" => "permission-set",
        "permissions" => [
          %{"type" => "permission", "resource" => "repo", "collection" => ["com.other.thing"]}
        ]
      }

      assert [] == Scopes.expand_include(inc, other)
    end

    test "a vendored permission set expands through the registry (app.bsky.authFullApp)" do
      g =
        Scopes.grant(
          "atproto include:app.bsky.authFullApp?aud=did:web:appview.aerox.sola.town%23bsky_appview"
        )

      assert g.atproto?

      assert Scopes.allows?(g, :rpc, %{
               lxm: "app.bsky.feed.getTimeline",
               aud: "did:web:appview.aerox.sola.town#bsky_appview"
             })

      assert Scopes.allows?(g, :repo, %{collection: "app.bsky.feed.post", action: "create"})
      refute Scopes.allows?(g, :repo, %{collection: "com.example.other", action: "create"})

      refute Scopes.allows?(g, :rpc, %{
               lxm: "app.bsky.feed.getTimeline",
               aud: "did:web:other.example"
             })
    end
  end

  describe "transition scopes" do
    test "email" do
      g = Scopes.grant("transition:email account:repo")
      assert Scopes.allows?(g, :account, %{attr: "email", action: "read"})
      refute Scopes.allows?(g, :account, %{attr: "email", action: "manage"})
      assert Scopes.allows?(g, :account, %{attr: "repo", action: "read"})
      refute Scopes.allows?(g, :account, %{attr: "repo", action: "manage"})
      refute Scopes.allows?(g, :account, %{attr: "status", action: "read"})
    end

    test "generic and chat.bsky" do
      g = Scopes.grant("transition:generic")
      assert Scopes.allows?(g, :blob, %{mime: "foo/bar"})
      assert Scopes.allows?(g, :repo, %{collection: "app.bsky.feed.post", action: "create"})
      assert Scopes.allows?(g, :repo, %{collection: "com.example.foo", action: "update"})
      assert Scopes.allows?(g, :rpc, %{aud: "did:web:example.com", lxm: "app.bsky.feed.post"})
      assert Scopes.allows?(g, :rpc, %{aud: "did:web:example.com", lxm: "*"})

      refute Scopes.allows?(g, :rpc, %{
               aud: "did:web:example.com",
               lxm: "chat.bsky.convo.listConvos"
             })

      c = Scopes.grant("transition:chat.bsky")

      assert Scopes.allows?(c, :rpc, %{
               aud: "did:web:example.com",
               lxm: "chat.bsky.convo.listConvos"
             })

      refute Scopes.allows?(c, :rpc, %{
               aud: "did:web:example.com",
               lxm: "app.bsky.feed.getTimeline"
             })

      assert {:error, {:scope_missing, "repo:com.example.foo?action=create"}} =
               Scopes.assert(c, :repo, %{collection: "com.example.foo", action: "create"})
    end
  end
end
