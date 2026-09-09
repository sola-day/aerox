defmodule Mix.Tasks.Aerox.Labeler.Setup do
  @shortdoc "Create (or complete) the labeler account on this PDS"
  @moduledoc """
  DESIGN §17.1: the labeler is an atproto account on our PDS. This task runs
  `Aerox.Labeler.Setup.ensure_account!/1` — creates the account when its
  handle is free, writes the `app.bsky.labeler.service` record, adds the
  `#atproto_labeler` service and the `#atproto_label` key to the DID
  document, and persists the DID and signing key in `labeler.setting` — and
  prints the values to export for a labeler that runs on another node.

      mix aerox.labeler.setup --handle labeler.aerox.sola.town --password <pw> [--email <addr>]
  """
  use Boundary, top_level?: true, deps: [Aerox.Labeler.Setup]
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [handle: :string, password: :string, email: :string])

    handle = opts[:handle] || Mix.raise("--handle is required")
    password = opts[:password] || Mix.raise("--password is required")

    Mix.Task.run("app.start")

    result =
      Aerox.Labeler.Setup.ensure_account!(
        Keyword.take([handle: handle, password: password, email: opts[:email]], [
          :handle,
          :password,
          :email
        ])
        |> Enum.reject(fn {_, v} -> is_nil(v) end)
      )

    Mix.shell().info("""
    labeler account #{if result.created?, do: "created", else: "ready"}:
      handle: #{result.handle}
      did:    #{result.did}

    For a labeler (or PDS) running on another node, export:
      AEROX_LABELER_DID=#{result.did}
      AEROX_LABELER_SIGNING_KEY_HEX=#{result.signing_key_hex}
    """)
  end
end
