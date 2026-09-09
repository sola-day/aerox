Code.require_file("helpers.exs", __DIR__)

defmodule Aerox.Labeler.ModerationTest do
  @moduledoc """
  VERIFICATION §5 Labeler: report intake, the append-only `mod_event` log
  (recorded before the action is applied), idempotent actions and replay
  from the log.
  """
  use Aerox.DataCase, async: false
  import Ecto.Query
  alias Aerox.Labeler.{Actions, Labels, Repo, Reports}
  alias Aerox.Labeler.Schema.ModEvent
  import Aerox.LabelerTestHelpers

  defmodule Recording do
    @moduledoc "An Actions implementation that records every call in the test process and fails on demand."
    @behaviour Aerox.Labeler.Actions
    def label(s, v, o), do: record({:label, s, v}, o)
    def unlabel(s, v, o), do: record({:unlabel, s, v}, o)
    def takedown(s, o), do: record({:takedown, s}, o)
    def restore(s, o), do: record({:restore, s}, o)
    def acknowledge(id, o), do: record({:acknowledge, id}, o)
    def comment(s, t, o), do: record({:comment, s, t}, o)

    defp record(call, %{event: event}) do
      send(Application.get_env(:aerox, :recording_test), {:applied, event.id, call})
      if Application.get_env(:aerox, :recording_fail), do: {:error, :boom}, else: :ok
    end
  end

  @did "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"
  @post "at://did:plc:aaaaaaaaaaaaaaaaaaaaaaaa/app.bsky.feed.post/3kabc"
  @repo_ref %{"$type" => "com.atproto.admin.defs#repoRef", "did" => @did}
  @strong_ref %{"$type" => "com.atproto.repo.strongRef", "uri" => @post}

  setup do
    labeler = configure_unit_labeler!()
    {:ok, labeler: labeler}
  end

  defp with_recording(fun) do
    original = Application.get_env(:aerox, Aerox.Labeler)
    Application.put_env(:aerox, Aerox.Labeler, Keyword.put(original, :actions, Recording))
    Application.put_env(:aerox, :recording_test, self())
    Application.put_env(:aerox, :recording_fail, false)

    try do
      fun.()
    after
      Application.put_env(:aerox, Aerox.Labeler, original)
      Application.delete_env(:aerox, :recording_test)
      Application.delete_env(:aerox, :recording_fail)
    end
  end

  test "reports are stored with a normalised subject and listed newest first with paging" do
    reporter = "did:plc:rrrrrrrrrrrrrrrrrrrrrrrr"

    {:ok, r1} =
      Reports.create(%{
        subject: @repo_ref,
        reason_type: "com.atproto.moderation.defs#reasonSpam",
        reason: "spam",
        reported_by: reporter
      })

    {:ok, r2} =
      Reports.create(%{
        subject:
          Map.put(
            @strong_ref,
            "cid",
            "bafyreidfayvfuwqa7qlnopdjiqrxzs6blmoeu4rujcjtnci5beludirz2a"
          ),
        reason_type: "com.atproto.moderation.defs#reasonRude",
        reported_by: reporter
      })

    assert {:error, "Invalid subject" <> _} =
             Reports.create(%{
               subject: %{"$type" => "com.atproto.admin.defs#repoRef", "did" => "nope"},
               reason_type: "x",
               reported_by: reporter
             })

    assert {[^r2, ^r1], nil} = Reports.list()
    assert {[^r1], nil} = Reports.list(subject: @did)
    assert {[^r2], nil} = Reports.list(subject: @post)
    assert {[^r2], cursor} = Reports.list(limit: 1)
    assert {[^r1], _} = Reports.list(limit: 1, cursor: cursor)

    assert Reports.view(r1) == %{
             "id" => r1.id,
             "reasonType" => "com.atproto.moderation.defs#reasonSpam",
             "reason" => "spam",
             "subject" => @repo_ref,
             "reportedBy" => reporter,
             "createdAt" => Aerox.ATProto.Syntax.format_datetime(r1.created_at)
           }
  end

  test "emit records the event before applying it, and marks it applied afterwards" do
    with_recording(fn ->
      {:ok, e} =
        Actions.emit(%{
          action: "label",
          subject: @strong_ref,
          created_by: "mod",
          meta: %{"val" => "spam"}
        })

      assert_receive {:applied, id, {:label, @strong_ref, "spam"}}
      assert id == e.id and e.applied_at != nil
      # the row existed when the implementation ran: the id it saw is the stored one
      assert Repo.get!(ModEvent, id).applied_at != nil

      # a failing application leaves the row unapplied
      Application.put_env(:aerox, :recording_fail, true)

      assert {:error, :boom} =
               Actions.emit(%{action: "takedown", subject: @repo_ref, created_by: "mod"})

      assert_receive {:applied, failed_id, {:takedown, @repo_ref}}
      assert Repo.get!(ModEvent, failed_id).applied_at == nil

      # replay re-applies only the unapplied event, in order
      Application.put_env(:aerox, :recording_fail, false)
      assert {:ok, [^failed_id]} = Actions.replay()
      assert_receive {:applied, ^failed_id, {:takedown, @repo_ref}}
      refute_receive {:applied, ^id, _}
      assert Repo.get!(ModEvent, failed_id).applied_at != nil

      # a full replay runs the whole log
      assert {:ok, [^id, ^failed_id]} = Actions.replay(all: true)
    end)
  end

  test "argument validation and the six actions" do
    with_recording(fn ->
      assert {:error, "label requires meta.val"} =
               Actions.emit(%{action: "label", subject: @repo_ref, created_by: "m", meta: %{}})

      assert {:error, "acknowledge requires meta.report"} =
               Actions.emit(%{
                 action: "acknowledge",
                 subject: @repo_ref,
                 created_by: "m",
                 meta: %{}
               })

      assert {:error, "comment requires a comment"} =
               Actions.emit(%{action: "comment", subject: @repo_ref, created_by: "m"})

      assert {:error, "unknown action: \"ban\""} =
               Actions.emit(%{action: "ban", subject: @repo_ref, created_by: "m"})

      assert {:ok, _} =
               Actions.emit(%{
                 action: "unlabel",
                 subject: @repo_ref,
                 created_by: "m",
                 meta: %{"val" => "spam"}
               })

      assert_receive {:applied, _, {:unlabel, @repo_ref, "spam"}}
      assert {:ok, _} = Actions.emit(%{action: "restore", subject: @repo_ref, created_by: "m"})
      assert_receive {:applied, _, {:restore, @repo_ref}}

      assert {:ok, _} =
               Actions.emit(%{
                 action: "acknowledge",
                 subject: @repo_ref,
                 created_by: "m",
                 meta: %{"report" => 7}
               })

      assert_receive {:applied, _, {:acknowledge, 7}}

      assert {:ok, _} =
               Actions.emit(%{
                 action: "comment",
                 subject: @strong_ref,
                 created_by: "m",
                 comment: "hmm"
               })

      assert_receive {:applied, _, {:comment, @strong_ref, "hmm"}}

      {events, nil} = Actions.list()
      assert Enum.map(events, & &1.action) == ~w(comment acknowledge restore unlabel)
      assert {[%{action: "comment"}], nil} = Actions.list(subject: @post)
      assert Repo.one(from(e in ModEvent, select: count())) == 4
    end)
  end

  test "the default implementation labels idempotently and replays without duplicates", ctx do
    label = %{action: "label", subject: @strong_ref, created_by: "mod", meta: %{"val" => "spam"}}
    {:ok, e1} = Actions.emit(label)
    {:ok, e2} = Actions.emit(label)
    assert e2.id > e1.id
    assert [%{val: "spam", neg: false, seq: seq}] = Labels.for_subject(@post)

    # the second emit was a no-op on the label table and the sequencer
    assert Aerox.Labeler.Sequencer.current() == seq

    {:ok, _} =
      Actions.emit(%{
        action: "unlabel",
        subject: @strong_ref,
        created_by: "mod",
        meta: %{"val" => "spam"}
      })

    assert [%{val: "spam", neg: true}] = Labels.for_subject(@post)
    refute Labels.applied?(@post, "spam")

    # replaying the whole log ends in the same state: label, label, unlabel
    assert {:ok, [_, _, _]} = Actions.replay(all: true)
    assert [%{val: "spam", neg: true}] = Labels.for_subject(@post)
    assert ctx.labeler.did == hd(Labels.for_subject(@post)).src

    # acknowledge and comment need only the log
    assert {:ok, %{applied_at: %DateTime{}}} =
             Actions.emit(%{
               action: "acknowledge",
               subject: @repo_ref,
               created_by: "mod",
               meta: %{"report" => 1}
             })
  end
end
