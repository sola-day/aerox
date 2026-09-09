defmodule Aerox.Identity.ResolverTest do
  @moduledoc "L6 identity: DNS-first then HTTPS handle resolution, did:plc and did:web documents, SSRF rules, bidirectional handle check."
  use ExUnit.Case, async: true
  import Mox
  alias Aerox.Identity.{HTTP, Resolver}

  setup :verify_on_exit!

  @doc_json %{
    "id" => "did:plc:ewvi7nxzyoun6zhxrhs64oiz",
    "alsoKnownAs" => ["at://atproto.com"],
    "verificationMethod" => [],
    "service" => []
  }

  defp plug_for(routes) do
    fn conn ->
      key = {conn.method, conn.host, conn.request_path}

      case Map.fetch(routes, key) do
        {:ok, {status, body}} -> Plug.Conn.send_resp(conn, status, body)
        :error -> Plug.Conn.send_resp(conn, 404, "no route for #{inspect(key)}")
      end
    end
  end

  test "handle: DNS TXT wins; a missing or ambiguous TXT falls back to the well-known" do
    Aerox.Identity.DNSMock
    |> expect(:txt, fn "_atproto.alice.test", _ ->
      {:ok, ["did=did:plc:ewvi7nxzyoun6zhxrhs64oiz"]}
    end)
    |> expect(:txt, fn "_atproto.bob.test", _ -> {:ok, ["did=did:plc:a", "did=did:plc:b"]} end)
    |> expect(:txt, fn "_atproto.carol.test", _ -> {:error, :nxdomain} end)

    plug =
      plug_for(%{
        {"GET", "bob.test", "/.well-known/atproto-did"} =>
          {200, "did:plc:ewvi7nxzyoun6zhxrhs64oiz\n"},
        {"GET", "carol.test", "/.well-known/atproto-did"} => {404, ""}
      })

    opts = [dns: Aerox.Identity.DNSMock, http: [plug: plug]]

    assert {:ok, "did:plc:ewvi7nxzyoun6zhxrhs64oiz"} = Resolver.resolve_handle("alice.test", opts)
    assert {:ok, "did:plc:ewvi7nxzyoun6zhxrhs64oiz"} = Resolver.resolve_handle("bob.test", opts)
    assert {:error, :not_found} = Resolver.resolve_handle("carol.test", opts)
    assert {:error, :invalid_handle} = Resolver.resolve_handle("not a handle", opts)
  end

  test "did:plc via the configured directory; did:web via /.well-known/did.json; id must match" do
    plug =
      plug_for(%{
        {"GET", "plc.test", "/did:plc:ewvi7nxzyoun6zhxrhs64oiz"} =>
          {200, Jason.encode!(@doc_json)},
        {"GET", "plc.test", "/did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"} => {404, ""},
        {"GET", "example.com", "/.well-known/did.json"} =>
          {200, Jason.encode!(%{@doc_json | "id" => "did:web:example.com"})},
        {"GET", "liar.com", "/.well-known/did.json"} => {200, Jason.encode!(@doc_json)}
      })

    opts = [plc_url: "https://plc.test", http: [plug: plug]]

    assert {:ok, %{"id" => "did:plc:ewvi7nxzyoun6zhxrhs64oiz"}} =
             Resolver.resolve_did("did:plc:ewvi7nxzyoun6zhxrhs64oiz", opts)

    assert {:error, :not_found} = Resolver.resolve_did("did:plc:aaaaaaaaaaaaaaaaaaaaaaaa", opts)

    assert {:ok, %{"id" => "did:web:example.com"}} =
             Resolver.resolve_did("did:web:example.com", opts)

    assert {:error, :poorly_formatted_did_document} =
             Resolver.resolve_did("did:web:liar.com", opts)

    assert {:error, :unsupported_did_web_path} =
             Resolver.resolve_did("did:web:example.com:user:alice", opts)

    assert {:error, {:unsupported_did_method, "key"}} = Resolver.resolve_did("did:key:zabc", opts)
  end

  test "bidirectional handle verification" do
    Aerox.Identity.DNSMock
    |> expect(:txt, 2, fn "_atproto.atproto.com", _ ->
      {:ok, ["did=did:plc:ewvi7nxzyoun6zhxrhs64oiz"]}
    end)

    plug =
      plug_for(%{
        {"GET", "plc.test", "/did:plc:ewvi7nxzyoun6zhxrhs64oiz"} =>
          {200, Jason.encode!(@doc_json)}
      })

    opts = [dns: Aerox.Identity.DNSMock, plc_url: "https://plc.test", http: [plug: plug]]

    assert {:ok, "did:plc:ewvi7nxzyoun6zhxrhs64oiz", _} =
             Resolver.verify_handle("ATProto.com", opts)

    other = %{@doc_json | "alsoKnownAs" => ["at://someone-else.com"]}

    plug2 =
      plug_for(%{
        {"GET", "plc.test", "/did:plc:ewvi7nxzyoun6zhxrhs64oiz"} => {200, Jason.encode!(other)}
      })

    assert {:error, :handle_mismatch} =
             Resolver.verify_handle("atproto.com", Keyword.put(opts, :http, plug: plug2))
  end

  test "SSRF rules: private addresses are refused unless allowed (VERIFICATION §9 image_origin_loopback_dev_only)" do
    refute HTTP.public_ip?({127, 0, 0, 1})
    refute HTTP.public_ip?({10, 1, 2, 3})
    refute HTTP.public_ip?({172, 18, 0, 1})
    refute HTTP.public_ip?({192, 168, 1, 1})
    refute HTTP.public_ip?({169, 254, 1, 1})
    refute HTTP.public_ip?({0, 0, 0, 0, 0, 0, 0, 1})
    refute HTTP.public_ip?({0xFD00, 0, 0, 0, 0, 0, 0, 1})
    assert HTTP.public_ip?({13, 231, 124, 25})
    assert HTTP.public_ip?({0x2606, 0x4700, 0, 0, 0, 0, 0, 1})

    assert {:error, {:private_address, "127.0.0.1"}} =
             HTTP.get("http://127.0.0.1:4000/", timeout: 200, allow_private: false)

    assert {:error, {:private_address, "localhost"}} =
             HTTP.check_host("localhost", false, plug: nil)

    assert :ok = HTTP.check_host("localhost", true)
    assert {:error, {:invalid_url, _}} = HTTP.get("ftp://x/")
  end
end
