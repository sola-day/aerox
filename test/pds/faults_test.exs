defmodule Aerox.PDS.FaultsTest do
  @moduledoc """
  VERIFICATION §10.2 (BEAM-specific faults), the in-process cases: kill the
  sequencer mid-batch and assert no lost and no duplicated seq; a slow
  firehose subscriber is disconnected rather than growing the node's memory;
  a relay consumer restarts from its cursor (covered by the consumer test).
  """
  use Aerox.DataCase, async: false
  alias Aerox.PDS.Sequencer
  alias Aerox.PDS.Sequencer.Events
  alias AeroxWeb.Sockets.Firehose

  test "killing the sequencer mid-stream loses nothing and duplicates nothing" do
    did = "did:plc:" <> String.duplicate("f", 24)
    before = Sequencer.current() || 0
    parent = self()

    writers =
      for w <- 1..8 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Aerox.PDS.Repo, parent, self())

          for i <- 1..25 do
            # a call may hit the restart window: retry it, exactly as a controller would
            result =
              Enum.reduce_while(1..20, nil, fn _, _ ->
                try do
                  {:cont_or_halt, Sequencer.sequence([Events.identity(did, "w#{w}-#{i}.test")])}
                catch
                  :exit, _ ->
                    Process.sleep(20)
                    {:cont, nil}
                else
                  {:cont_or_halt, {:ok, _} = ok} -> {:halt, ok}
                  {:cont_or_halt, other} -> {:halt, other}
                end
              end)

            result
          end
        end)
      end

    # kill the sequencer a few times while the writers run; rest_for_one restarts it
    for _ <- 1..3 do
      Process.sleep(30)
      if pid = Process.whereis(Sequencer), do: Process.exit(pid, :kill)
    end

    results = writers |> Enum.map(&Task.await(&1, 30_000)) |> List.flatten()
    acked = for {:ok, [seq]} <- results, do: seq
    assert length(acked) >= 150, "most writes succeed; #{length(acked)} acked"

    # every acked seq exists exactly once, and the table has no gaps between
    # the first and last acked seq
    rows = Sequencer.range(before, 10_000)
    seqs = Enum.map(rows, & &1.seq)
    assert Enum.uniq(seqs) == seqs
    assert Enum.all?(acked, &(&1 in seqs))
    assert seqs == Enum.to_list(hd(seqs)..List.last(seqs))
    assert Process.whereis(Sequencer) != nil
  end

  test "a slow firehose subscriber is disconnected with ConsumerTooSlow instead of growing its mailbox" do
    {:ok, state} = Firehose.init(%{cursor: nil, source: Aerox.PDS.Sequencer.Source})
    # flood our own mailbox past the threshold, as an unread socket would
    for i <- 1..5_100, do: send(self(), {:noise, i})

    rows = [
      %{
        seq: 1,
        did: "did:plc:x",
        event_type: "identity",
        event: Aerox.ATProto.DagCBOR.encode(%{"did" => "did:plc:x"}),
        sequenced_at: DateTime.utc_now()
      }
    ]

    assert {:stop, :normal, {1008, "ConsumerTooSlow"}, _} =
             Firehose.handle_info({:firehose, rows}, state)

    # drain
    for _ <- 1..5_100, do: receive(do: ({:noise, _} -> :ok))
    assert {:push, [_], _} = Firehose.handle_info({:firehose, rows}, state)
  end
end
