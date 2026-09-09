defmodule Aerox.Labeler.Actions do
  @moduledoc """
  The moderation actions behaviour DESIGN §17.2 calls `Aerox.Moderation.Actions`
  (it lives here to stay inside the Labeler boundary; the name is a
  location, not a contract): exactly `label` / `unlabel` (subject, val),
  `takedown` / `restore` (an account, record or blob subject),
  `acknowledge` (a report) and `comment`.

  `emit/1` is the single entry point: the event is appended to
  `labeler.mod_event` **before** it is applied, then applied through the
  configured implementation (`Aerox.Labeler.Config.actions/0`, default
  `Aerox.Labeler.Actions.Default`) and marked `applied_at`. Every
  implementation must be idempotent, so a crash between the two steps is
  repaired by `replay/0`, which re-applies every unapplied event in order —
  or the whole log with `replay(all: true)`.
  """
  import Ecto.Query
  alias Aerox.ATProto.Syntax
  alias Aerox.Labeler.{Config, Repo, Subject}
  alias Aerox.Labeler.Schema.ModEvent

  @type subject :: map
  @type opts :: %{event: ModEvent.t()}

  @callback label(subject, val :: String.t(), opts) :: :ok | {:error, term}
  @callback unlabel(subject, val :: String.t(), opts) :: :ok | {:error, term}
  @callback takedown(subject, opts) :: :ok | {:error, term}
  @callback restore(subject, opts) :: :ok | {:error, term}
  @callback acknowledge(report_id :: integer, opts) :: :ok | {:error, term}
  @callback comment(subject, text :: String.t(), opts) :: :ok | {:error, term}

  @actions ~w(label unlabel takedown restore acknowledge comment)
  def actions, do: @actions

  @type event_attrs :: %{
          required(:action) => String.t(),
          required(:subject) => subject,
          required(:created_by) => String.t(),
          optional(:comment) => String.t() | nil,
          optional(:meta) => map
        }

  @doc """
  Records and applies an action. `meta` carries the action's arguments:
  `%{"val" => …}` for label/unlabel, `%{"report" => id}` for acknowledge.
  Returns the applied event.
  """
  @spec emit(event_attrs) :: {:ok, ModEvent.t()} | {:error, term}
  def emit(attrs) do
    with :ok <- validate(attrs),
         {:ok, subject} <- Subject.normalize(attrs.subject),
         {:ok, event} <-
           Repo.insert(%ModEvent{
             action: attrs.action,
             subject: subject,
             created_by: attrs.created_by,
             comment: attrs[:comment],
             meta: attrs[:meta] || %{},
             created_at: DateTime.utc_now()
           }),
         :ok <- apply_event(event) do
      {:ok, mark_applied(event)}
    end
  end

  defp validate(%{action: action, meta: meta}) when action in ["label", "unlabel"] do
    if is_binary(meta["val"]) and meta["val"] != "",
      do: :ok,
      else: {:error, "#{action} requires meta.val"}
  end

  defp validate(%{action: "acknowledge", meta: meta}) do
    if is_integer(meta["report"]), do: :ok, else: {:error, "acknowledge requires meta.report"}
  end

  defp validate(%{action: "comment"} = attrs) do
    if is_binary(attrs[:comment]), do: :ok, else: {:error, "comment requires a comment"}
  end

  defp validate(%{action: action}) when action in @actions, do: :ok
  defp validate(%{action: action}), do: {:error, "unknown action: #{inspect(action)}"}
  defp validate(_), do: {:error, "action is required"}

  @doc "Applies one stored event through the configured implementation."
  @spec apply_event(ModEvent.t()) :: :ok | {:error, term}
  def apply_event(%ModEvent{} = e) do
    impl = Config.actions()
    opts = %{event: e}

    case e.action do
      "label" -> impl.label(e.subject, e.meta["val"], opts)
      "unlabel" -> impl.unlabel(e.subject, e.meta["val"], opts)
      "takedown" -> impl.takedown(e.subject, opts)
      "restore" -> impl.restore(e.subject, opts)
      "acknowledge" -> impl.acknowledge(e.meta["report"], opts)
      "comment" -> impl.comment(e.subject, e.comment || "", opts)
    end
  end

  defp mark_applied(event) do
    now = DateTime.utc_now()
    Repo.update_all(from(e in ModEvent, where: e.id == ^event.id), set: [applied_at: now])
    %{event | applied_at: now}
  end

  @doc "Re-applies unapplied events (or every event with `all: true`) in log order; returns the ids applied."
  @spec replay(keyword) :: {:ok, [integer]} | {:error, {integer, term}}
  def replay(opts \\ []) do
    q = from(e in ModEvent, order_by: [asc: e.id])
    q = if opts[:all], do: q, else: where(q, [e], is_nil(e.applied_at))

    q
    |> Repo.all()
    |> Enum.reduce_while({:ok, []}, fn e, {:ok, acc} ->
      case apply_event(e) do
        :ok ->
          mark_applied(e)
          {:cont, {:ok, [e.id | acc]}}

        {:error, reason} ->
          {:halt, {:error, {e.id, reason}}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      e -> e
    end
  end

  @doc "Events, newest first; `subject:` filters, `cursor:` is the previous page's last id."
  @spec list(keyword) :: {[ModEvent.t()], String.t() | nil}
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    q = from(e in ModEvent, order_by: [desc: e.id], limit: ^limit)
    q = Subject.filter(q, Keyword.get(opts, :subject))

    q =
      case Keyword.get(opts, :cursor) do
        nil -> q
        "" -> q
        cursor -> where(q, [e], e.id < ^String.to_integer(cursor))
      end

    rows = Repo.all(q)
    next = if length(rows) == limit, do: Integer.to_string(List.last(rows).id)
    {rows, next}
  end

  @doc "The takedown ref an event applies: `mod_event:<id>`, so a takedown traces back to the log."
  def takedown_ref(%ModEvent{id: id}), do: "mod_event:#{id}"

  @doc "The `aerox.moderation.defs#modEventView` shape."
  def view(%ModEvent{} = e) do
    %{
      "id" => e.id,
      "action" => e.action,
      "subject" => e.subject,
      "createdBy" => e.created_by,
      "comment" => e.comment,
      "meta" => e.meta,
      "createdAt" => Syntax.format_datetime(e.created_at),
      "appliedAt" => e.applied_at && Syntax.format_datetime(e.applied_at)
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end
end

defmodule Aerox.Labeler.Actions.Default do
  @moduledoc """
  The default `Aerox.Labeler.Actions`: labels go through
  `Aerox.Labeler.Labels` (idempotent: re-labelling an applied value is a
  no-op, unlabelling an absent one too); takedowns and restores go to the
  subject's PDS admin API (`com.atproto.admin.updateSubjectStatus`, service
  JWT signed by the labeler key, DESIGN §17.2) through
  `Aerox.Labeler.PDSClient`, and to the AppView in the same node through
  `Aerox.AppView.Moderation` when one runs here (`record.takedown_ref`,
  `actor.takedown_ref`, image-cache purge); a remote AppView learns account
  takedowns from the `#account` firehose event the PDS emits. Acknowledge
  and comment only need the log.
  """
  @behaviour Aerox.Labeler.Actions
  alias Aerox.Labeler.{Actions, Labels, PDSClient, Subject}

  @impl true
  def label(subject, val, _opts) do
    uri = Subject.label_uri(subject)

    if Labels.applied?(uri, val) do
      :ok
    else
      with {:ok, _} <- Labels.create(%{uri: uri, cid: subject["cid"], val: val}), do: :ok
    end
  end

  @impl true
  def unlabel(subject, val, _opts) do
    uri = Subject.label_uri(subject)

    if Labels.applied?(uri, val) do
      with {:ok, _} <- Labels.negate(uri, subject["cid"], val), do: :ok
    else
      :ok
    end
  end

  @impl true
  def takedown(subject, %{event: event}),
    do: set_takedown(subject, Actions.takedown_ref(event))

  @impl true
  def restore(subject, _opts), do: set_takedown(subject, nil)

  @impl true
  def acknowledge(_report_id, _opts), do: :ok

  @impl true
  def comment(_subject, _text, _opts), do: :ok

  defp set_takedown(subject, ref) do
    with :ok <- PDSClient.update_takedown(subject, ref) do
      appview_takedown(subject, ref)
    end
  end

  # In-node AppView propagation (DESIGN §15.6): resolved at runtime so the
  # Labeler boundary never depends on Aerox.AppView; `nil` when the AppView
  # runs elsewhere (it then learns account takedowns from the firehose only).
  defp appview_takedown(subject, ref) do
    case appview_moderation() do
      nil ->
        :ok

      mod ->
        case Subject.kind(subject) do
          :account -> mod.set_actor_takedown(subject["did"], ref)
          :record -> mod.set_record_takedown(subject["uri"], ref)
          :blob -> mod.purge_blob(subject["did"], subject["cid"])
        end

        :ok
    end
  end

  defp appview_moderation do
    case Aerox.Labeler.Config.get(:appview_moderation, :default) do
      :default ->
        mod = Aerox.AppView.Moderation

        if Code.ensure_loaded?(mod) and function_exported?(mod, :enabled?, 0) and mod.enabled?(),
          do: mod

      mod ->
        mod
    end
  end
end
