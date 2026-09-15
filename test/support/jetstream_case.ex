defmodule Aerox.JetstreamCase do
  @moduledoc """
  Jetstream tests: a sandboxed `jetstream` schema, a private data directory,
  small blocks and segments, a manifest reloaded from that directory, and a
  running writer.
  """
  use Boundary, top_level?: true, deps: [Aerox.DataCase, Aerox.Jetstream, Aerox.ATProto]
  use ExUnit.CaseTemplate

  using do
    quote do
      import Aerox.JetstreamCase
      alias Aerox.Jetstream.{Event, Manifest, Tail, Writer}
    end
  end

  setup tags do
    Aerox.DataCase.setup_sandbox(Aerox.DataCase.all_repos(), tags)
    dir = Path.join(System.tmp_dir!(), "aerox-jetstream-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    original = Application.get_env(:aerox, Aerox.Jetstream, [])

    Application.put_env(
      :aerox,
      Aerox.Jetstream,
      Keyword.merge(original,
        data_dir: dir,
        max_events_per_block: tags[:block] || 3,
        segment_bytes: tags[:segment_bytes] || 1_000_000_000,
        block_max_age_ms: 3_600_000
      )
    )

    :ok = Aerox.Jetstream.Manifest.reload()

    on_exit(fn ->
      Application.put_env(:aerox, Aerox.Jetstream, original)
      File.rm_rf!(dir)
    end)

    unless tags[:no_writer], do: ExUnit.Callbacks.start_supervised!(Aerox.Jetstream.Writer)
    {:ok, dir: dir}
  end

  @doc "A create row for `did`."
  def create(did, n, collection \\ "app.bsky.feed.post") do
    %Aerox.Jetstream.Event{
      kind: :create,
      did: did,
      collection: collection,
      rkey: "3k#{String.pad_leading(Integer.to_string(n), 11, "a")}",
      rev: "3kaaaaaaaaa22",
      payload: Aerox.ATProto.DagCBOR.encode(%{"$type" => collection, "text" => "row #{n}"})
    }
  end

  @doc "Everything readable from `cursor`, block by block."
  def read_all(cursor \\ 0) do
    case Aerox.Jetstream.Tail.read_from(cursor, 1000) do
      {:ok, [], _} -> []
      {:ok, rows, next} -> rows ++ read_all(next)
    end
  end
end
