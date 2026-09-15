defmodule Aerox.Jetstream.Wire do
  @moduledoc """
  What subscribers receive (upstream `internal/subscribe/encoder.go`).

  **v1** (`/subscribe`, frozen jetstream-v1 JSON): `{did, time_us, cursor,
  kind, commit | identity | account}`, the record decoded to JSON with its CID;
  `#sync` and resync replacement rows are not part of v1.

  **v2** (`network.bsky.jetstream.subscribeEvents`, proposal 0015
  `xrpc.v1.json`): `{"$type":"message","payload":{"$type":"…#commit", seq,
  did, time, …}}`; identity, account and sync wrap the upstream event; errors
  are `{"$type":"error","error":…,"message":…}`.

  Compression is dictionary zstd: the legacy dictionary for v1, the
  `subscribeEvents` dictionary (fetched with `getZstdDictionary`) for v2.
  """
  alias Aerox.ATProto.{Data, DagCBOR}
  alias Aerox.Jetstream.{Convert, Event}

  @nsid "network.bsky.jetstream.subscribeEvents"

  # ------------------------------------------------------------------ v1

  @spec v1(Event.t()) :: {:ok, binary} | :skip | {:error, term}
  def v1(%Event{kind: k}) when k in [:sync, :create_resync], do: :skip

  def v1(%Event{} = e) do
    base = %{"did" => e.did, "time_us" => Event.display_time_us(e), "cursor" => e.seq}

    with {:ok, body} <- v1_body(e) do
      {:ok, Jason.encode!(Map.merge(base, body))}
    end
  end

  defp v1_body(%Event{kind: :identity} = e),
    do: upstream(e, "identity", fn m -> %{"kind" => "identity", "identity" => m} end)

  defp v1_body(%Event{kind: :account} = e),
    do: upstream(e, "account", fn m -> %{"kind" => "account", "account" => m} end)

  defp v1_body(%Event{} = e) do
    with {:ok, commit} <- commit(e) do
      {:ok, %{"kind" => "commit", "commit" => commit}}
    end
  end

  # ------------------------------------------------------------------ v2

  @spec v2(Event.t()) :: {:ok, binary} | {:error, term}
  def v2(%Event{} = e) do
    common = %{"seq" => e.seq, "did" => e.did, "time" => time(Event.display_time_us(e))}

    payload =
      case e.kind do
        k when k in [:create, :update, :delete, :create_resync] ->
          with {:ok, commit} <- commit(e) do
            {:ok, Map.merge(common, Map.put(commit, "$type", @nsid <> "#commit"))}
          end

        k when k in [:identity, :account, :sync] ->
          name = Atom.to_string(k)

          upstream(e, name, fn m ->
            common |> Map.put("$type", @nsid <> "#" <> name) |> Map.put(name, m)
          end)
      end

    with {:ok, p} <- payload do
      {:ok, Jason.encode!(%{"$type" => "message", "payload" => p})}
    end
  end

  def v2_error(code, message) do
    %{"$type" => "error", "error" => code}
    |> then(&if(message in [nil, ""], do: &1, else: Map.put(&1, "message", message)))
    |> Jason.encode!()
  end

  def v2_info(name, message) do
    info = %{"$type" => @nsid <> "#info", "name" => name}
    info = if message in [nil, ""], do: info, else: Map.put(info, "message", message)
    Jason.encode!(%{"$type" => "message", "payload" => info})
  end

  # ---------------------------------------------------------------- parts

  defp commit(%Event{} = e) do
    op =
      case e.kind do
        k when k in [:create, :create_resync] -> "create"
        :update -> "update"
        :delete -> "delete"
      end

    base = %{"rev" => e.rev, "operation" => op, "collection" => e.collection, "rkey" => e.rkey}

    if e.kind == :delete do
      {:ok, base}
    else
      case DagCBOR.decode(e.payload) do
        {:ok, record} ->
          {:ok,
           base
           |> Map.put("record", Data.to_json(record))
           |> Map.put("cid", Convert.cid(e.payload))}

        {:error, reason} ->
          {:error, {:record, reason}}
      end
    end
  end

  defp upstream(%Event{payload: payload}, _name, wrap) do
    case DagCBOR.decode(payload) do
      {:ok, %{} = m} -> {:ok, wrap.(Data.to_json(m))}
      {:ok, _} -> {:error, :not_an_object}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "`2006-01-02T15:04:05.000000Z` from unix microseconds."
  def time(us) do
    us |> DateTime.from_unix!(:microsecond) |> Calendar.strftime("%Y-%m-%dT%H:%M:%S.%fZ")
  end

  # ----------------------------------------------------------- compression

  @dicts %{
    v1: "legacy_subscribe.zdict",
    v2: "subscribe_events_20260811.zdict"
  }

  @doc "The raw dictionary bytes (`getZstdDictionary` serves the v2 one)."
  def dictionary(which), do: which |> dict_state() |> Map.fetch!(:bytes)

  @doc "The zstd dictionary id embedded in a structured dictionary's header."
  def dictionary_id(which), do: which |> dict_state() |> Map.fetch!(:id)

  @doc "One dictionary-compressed zstd frame whose content is `frame`."
  def compress(which, frame) do
    %{cdict: cdict, window: window} = dict_state(which)
    frame |> :zstd.compress(%{dictionary: cdict, windowLog: window}) |> IO.iodata_to_binary()
  end

  @doc "Decompresses a frame produced by `compress/2` (tests, clients)."
  def decompress(which, frame) do
    %{ddict: ddict} = dict_state(which)
    frame |> :zstd.decompress(%{dictionary: ddict}) |> IO.iodata_to_binary()
  end

  defp dict_state(which) do
    key = {__MODULE__, which}

    case :persistent_term.get(key, nil) do
      nil ->
        bytes =
          File.read!(Path.join(:code.priv_dir(:aerox), "jetstream/" <> Map.fetch!(@dicts, which)))

        <<0xEC30A437::little-32, id::little-32, _::binary>> = bytes
        level = if which == :v2, do: 1, else: 3
        {:ok, cdict} = :zstd.dict(:compress, bytes, %{compressionLevel: level})
        {:ok, ddict} = :zstd.dict(:decompress, bytes)
        state = %{bytes: bytes, id: id, cdict: cdict, ddict: ddict, window: 17}
        :persistent_term.put(key, state)
        state

      state ->
        state
    end
  end
end
