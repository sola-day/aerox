defmodule Aerox.AppViewHelpers do
  @moduledoc """
  Helpers for AppView endpoint tests: accounts created on our PDS, records
  written through the PDS write path and indexed by feeding the resulting
  firehose events to the ingest indexer (the `Aerox.AppView.IndexingTest`
  pattern), service JWTs for a viewer, and lexicon validation of responses.
  """
  use Boundary,
    top_level?: true,
    deps: [Aerox.PDS, Aerox.AppView, Aerox.ATProto, Aerox.Auth]

  import ExUnit.Assertions
  alias Aerox.PDS.Records
  alias Aerox.PDS.Records.Prepare
  alias Aerox.PDS.Sequencer, as: PdsSeq
  alias Aerox.AppView.Ingest.Indexer
  alias Aerox.ATProto.Lexicon

  def signup(name) do
    {:ok, account} =
      Aerox.PDS.Signup.create(%{
        handle: "#{name}.aerox.sola.town",
        email: "#{name}@example.com",
        password: "pw-pw-pw-pw"
      })

    account
  end

  @doc "Writes through the PDS, then indexes every new firehose event."
  def write!(did, writes) do
    before = PdsSeq.current() || 0
    {:ok, commit} = Records.process_writes(did, writes)
    ingest_since(before)
    commit
  end

  def ingest_since(seq) do
    for row <- PdsSeq.range(seq, 1000) do
      {type, body} = PdsSeq.Events.to_frame(row)
      assert :ok = Indexer.process(type, body), "#{type} seq=#{row.seq}"
    end
  end

  def create(did, collection, record, opts \\ []) do
    {:ok, w} = Prepare.create(did, collection, Map.put(record, "$type", collection), opts)
    w
  end

  def now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  @doc "A service JWT from the caller's PDS signing key for the given method."
  def service_jwt(did, nsid) do
    Aerox.Auth.ServiceJWT.create(
      keypair: Aerox.PDS.Accounts.signing_keypair(did),
      iss: did,
      aud: Aerox.AppView.Config.service_did(),
      lxm: nsid
    )
  end

  @doc "Asserts a 200 response whose body validates against the method's output schema."
  def valid_json!(conn, nsid) do
    body = Phoenix.ConnTest.json_response(conn, 200)

    case Lexicon.validate_output(Lexicon.default_registry(), nsid, body) do
      {:ok, _} -> body
      {:error, {msg, path}} -> flunk("#{nsid} output invalid: #{msg} at #{inspect(path)}")
    end
  end
end
