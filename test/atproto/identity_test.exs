defmodule Aerox.ATProto.IdentityTest do
  use ExUnit.Case, async: true
  alias Aerox.ATProto.Identity

  @doc_json ~s({
    "@context": ["https://www.w3.org/ns/did/v1"],
    "id": "did:plc:ewvi7nxzyoun6zhxrhs64oiz",
    "alsoKnownAs": ["at://atproto.com"],
    "verificationMethod": [{
      "id": "did:plc:ewvi7nxzyoun6zhxrhs64oiz#atproto",
      "type": "Multikey",
      "controller": "did:plc:ewvi7nxzyoun6zhxrhs64oiz",
      "publicKeyMultibase": "zQ3shunBKsXixLxKtC5qeSG9E4J5RkGN57im31pcTzbNQnm5w"
    }],
    "service": [{
      "id": "#atproto_pds",
      "type": "AtprotoPersonalDataServer",
      "serviceEndpoint": "https://enoki.us-east.host.bsky.network"
    }, {
      "id": "#atproto_labeler",
      "type": "AtprotoLabeler",
      "serviceEndpoint": "https://mod.example"
    }]
  })

  setup do
    {:ok, doc: Jason.decode!(@doc_json)}
  end

  test "parses did, handle, signing key and pds endpoint", %{doc: doc} do
    assert Identity.valid_doc?(doc)
    assert Identity.did(doc) == "did:plc:ewvi7nxzyoun6zhxrhs64oiz"
    assert Identity.handle(doc) == "atproto.com"

    assert {:ok, "did:key:zQ3shunBKsXixLxKtC5qeSG9E4J5RkGN57im31pcTzbNQnm5w"} =
             Identity.signing_did_key(doc)

    assert Identity.pds_endpoint(doc) == "https://enoki.us-east.host.bsky.network"
    assert Identity.labeler_endpoint(doc) == "https://mod.example"
    assert Identity.service_endpoint(doc, "#atproto_pds", "WrongType") == nil
    assert Identity.feed_generator_endpoint(doc) == nil
    assert %{"#atproto_pds" => %{type: "AtprotoPersonalDataServer"}} = Identity.services(doc)
  end

  test "ids are matched in both fragment and absolute form; unknown keys are addressable", %{
    doc: doc
  } do
    doc =
      update_in(
        doc["verificationMethod"],
        &[
          %{
            "id" => "#atproto_space",
            "type" => "Multikey",
            "publicKeyMultibase" => "zQ3shunBKsXixLxKtC5qeSG9E4J5RkGN57im31pcTzbNQnm5w"
          }
          | &1
        ]
      )

    assert {:ok, _} = Identity.did_key_for(doc, "atproto_space")
    assert {:ok, _} = Identity.did_key_for(doc, "atproto")
    assert :error = Identity.did_key_for(doc, "nope")
  end

  test "rejects non-http endpoints and malformed docs", %{doc: doc} do
    doc =
      put_in(doc["service"], [
        %{
          "id" => "#atproto_pds",
          "type" => "AtprotoPersonalDataServer",
          "serviceEndpoint" => "ftp://x"
        }
      ])

    assert Identity.pds_endpoint(doc) == nil
    refute Identity.valid_doc?(%{"id" => 1})
    refute Identity.valid_doc?(%{"id" => "did:x:y", "service" => "nope"})
  end
end
