defmodule Aerox.AppView.Ingest do
  @moduledoc """
  The Broadway ingest pipeline (DESIGN §21.5): firehose producer →
  processors partitioned by `hash(did)` so one repo's events stay ordered
  while repos proceed in parallel → `Indexer`. A failed event is logged
  and acked (the Relay already verified it; a failure here is a local bug
  or a transient DB error that the next event of the repo will surface).
  """
  use Broadway
  require Logger
  alias Aerox.AppView.Ingest.Indexer

  def start_link(opts) do
    url = Keyword.get(opts, :url) || Aerox.AppView.Config.relay_url()
    concurrency =
      Keyword.get(opts, :concurrency) || Aerox.AppView.Config.ingest_concurrency()

    Broadway.start_link(__MODULE__,
      name: Keyword.get(opts, :name, __MODULE__),
      producer: [
        module:
          {Aerox.AppView.Ingest.Producer,
           [
             url: url,
             service: URI.parse(url).host || url,
             connect: Keyword.get(opts, :connect, true)
           ]},
        concurrency: 1
      ],
      processors: [default: [concurrency: concurrency, max_demand: 10]],
      partition_by: &partition/1
    )
  end

  defp partition(%Broadway.Message{data: %{did: did}}), do: :erlang.phash2(did || "")

  @impl true
  def handle_message(_, %Broadway.Message{data: %{type: type, body: body, seq: seq}} = message, _) do
    case Indexer.process(type, body) do
      :ok ->
        message

      {:skip, reason} ->
        Logger.debug("appview: skipped seq=#{seq} #{type}: #{inspect(reason)}")
        message
    end
  rescue
    e ->
      Logger.error("appview: indexing failed seq=#{seq} #{type}: #{Exception.message(e)}")
      message
  end
end
