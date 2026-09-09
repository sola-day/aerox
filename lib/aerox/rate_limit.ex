defmodule Aerox.RateLimit do
  @moduledoc """
  Per-node rate limiting on Hammer's ETS backend (DESIGN §18.2). No Redis:
  this node is single-node until R3, at which point the backend swaps behind
  Hammer's interface.

  Two layers:

    * `check/4` is the raw primitive — one fixed-window bucket, any key.
    * `limits/0` and `hit/3` are the named limits routes declare
      (`plug AeroxWeb.Plugs.RateLimit, :create_session`). Each name maps to one
      or more buckets, all of which must allow; the reported status is the
      tightest bucket, as in upstream's `CombinedRateLimiter`.

  The numbers mirror upstream's PDS so operators and clients see familiar
  behaviour. Repo writes are points-based: see `write_points/1`.

  ## Configuration

      config :aerox, Aerox.RateLimit, overrides: %{create_session: [%{scale_ms: 60_000, limit: 2, key: :identifier_ip}]}

  `overrides` replaces the bucket list of a named limit wholesale (it does not
  merge). It is read on every call, so tests can `Application.put_env/3` it
  and `reset/0` the table; the test config leaves it empty so the defaults are
  what get exercised unless a test opts in.
  """
  use Hammer, backend: :ets

  @minute :timer.minutes(1)
  @five_minutes :timer.minutes(5)
  @hour :timer.hours(1)
  @day :timer.hours(24)

  @type key_kind :: :ip | :did | :identifier_ip
  @type bucket :: %{scale_ms: pos_integer, limit: pos_integer, key: key_kind}
  @type name :: atom
  @type status :: %{
          limit: pos_integer,
          remaining: non_neg_integer,
          reset_ms: non_neg_integer,
          scale_ms: pos_integer
        }

  @email_token [%{scale_ms: @minute, limit: 15, key: :did}]

  @limits %{
    global_ip: [%{scale_ms: @five_minutes, limit: 3000, key: :ip}],
    repo_write: [
      %{scale_ms: @hour, limit: 5000, key: :did},
      %{scale_ms: @day, limit: 35_000, key: :did}
    ],
    create_account: [%{scale_ms: @five_minutes, limit: 100, key: :ip}],
    upload_blob: [%{scale_ms: @day, limit: 1000, key: :did}],
    create_session: [
      %{scale_ms: @five_minutes, limit: 30, key: :identifier_ip},
      %{scale_ms: @day, limit: 300, key: :identifier_ip}
    ],
    update_handle: [
      %{scale_ms: @five_minutes, limit: 10, key: :did},
      %{scale_ms: @day, limit: 50, key: :did}
    ],
    request_email_confirmation: @email_token,
    request_password_reset: @email_token,
    request_email_update: @email_token,
    request_plc_operation_signature: @email_token,
    request_account_delete: @email_token,
    reset_password: [%{scale_ms: @five_minutes, limit: 50, key: :ip}]
  }

  # Upstream's calcPoints for applyWrites / createRecord / putRecord / deleteRecord.
  @write_points %{create: 3, update: 2, delete: 1}

  @doc """
  The named limits: name → buckets. Every bucket of a name shares the key kind.
  Overrides from `config :aerox, Aerox.RateLimit, overrides:` win per name.
  """
  @spec limits() :: %{name => [bucket]}
  def limits do
    overrides =
      :aerox
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:overrides, %{})

    Map.merge(@limits, Map.new(overrides))
  end

  @spec fetch_limit!(name) :: [bucket]
  def fetch_limit!(name) do
    case Map.fetch(limits(), name) do
      {:ok, buckets} -> buckets
      :error -> raise ArgumentError, "unknown rate limit #{inspect(name)}"
    end
  end

  @doc "Points a repo write costs against `:repo_write` (create 3, update/put 2, delete 1)."
  @spec write_points(:create | :update | :delete) :: pos_integer
  def write_points(op), do: Map.fetch!(@write_points, op)

  @doc """
  Hit one fixed-window bucket. `{:allow, remaining}` or `{:deny, retry_after_ms}`.
  A denied hit still counts, as in upstream's rate-limiter-flexible.
  """
  @spec check(term, pos_integer, pos_integer, pos_integer) ::
          {:allow, non_neg_integer} | {:deny, non_neg_integer}
  def check(key, scale_ms, limit, cost \\ 1)
      when is_integer(scale_ms) and scale_ms > 0 and is_integer(limit) and limit > 0 and
             is_integer(cost) and cost >= 0 do
    case hit(key, scale_ms, limit, cost) do
      {:allow, count} -> {:allow, max(limit - count, 0)}
      {:deny, retry_after_ms} -> {:deny, retry_after_ms}
    end
  end

  @doc """
  Hit every bucket of a named limit for `subject` (the resolved IP, DID or
  identifier+ip). Returns the tightest status; `:deny` if any bucket denies.
  """
  @spec hit_named(name, term, pos_integer) :: {:allow, status} | {:deny, status}
  def hit_named(name, subject, cost \\ 1) do
    name
    |> fetch_limit!()
    |> Enum.map(fn %{scale_ms: scale_ms, limit: limit} ->
      # scale in the key: Hammer's window number is div(now, scale), so two
      # buckets on the same key with different scales would otherwise collide.
      key = {name, scale_ms, subject}
      {verdict, _} = result = check(key, scale_ms, limit, cost)
      {verdict, status(result, key, scale_ms, limit)}
    end)
    |> Enum.reduce(fn {v, s}, {acc_v, acc_s} ->
      cond do
        v == :deny and acc_v != :deny -> {v, s}
        acc_v == :deny -> {acc_v, acc_s}
        s.remaining < acc_s.remaining -> {v, s}
        true -> {acc_v, acc_s}
      end
    end)
  end

  @doc "Drop every bucket. For tests."
  @spec reset() :: :ok
  def reset do
    true = :ets.delete_all_objects(__MODULE__)
    :ok
  end

  defp status({:deny, retry_after_ms}, _key, scale_ms, limit),
    do: %{limit: limit, remaining: 0, reset_ms: retry_after_ms, scale_ms: scale_ms}

  defp status({:allow, remaining}, key, scale_ms, limit) do
    reset_ms =
      case expires_at(key, scale_ms) do
        0 -> scale_ms
        at -> max(at - System.system_time(:millisecond), 0)
      end

    %{limit: limit, remaining: remaining, reset_ms: reset_ms, scale_ms: scale_ms}
  end
end
