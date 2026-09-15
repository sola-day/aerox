defmodule Aerox.PDS.PhoneVerification do
  @moduledoc """
  SMS verification at signup (`com.atproto.temp.requestPhoneVerification`, and
  `createAccount`'s `verificationPhone` / `verificationCode`).

  Off unless `config :aerox, Aerox.PDS, phone_verification: [adapter: ...]`
  names an adapter (`Aerox.PDS.SMS.Log` for development, `Aerox.PDS.SMS.Twilio`
  for real messages). When on, `describeServer` says
  `phoneVerificationRequired` and signup needs a code sent to the number within
  the last ten minutes; five wrong guesses spend the code. Codes are stored
  hashed and a number can be sent at most one code a minute.
  """
  import Ecto.Query
  alias Aerox.PDS.{Config, Repo}
  alias Aerox.PDS.Schema.PhoneVerification

  @ttl_s 600
  @resend_after_s 60
  @max_attempts 5

  @doc "Is phone verification on?"
  def required?, do: adapter() != nil

  defp adapter, do: (Config.get(:phone_verification) || [])[:adapter]

  defp enabled_adapter do
    case adapter() do
      nil -> {:error, {"InvalidRequest", "Phone verification is not enabled on this server"}}
      mod -> {:ok, mod}
    end
  end

  @doc "E.164 (`+` and 7–15 digits), spaces, dashes and parentheses removed."
  @spec normalize(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize(phone) when is_binary(phone) do
    n = String.replace(phone, ~r/[\s\-()]/, "")

    if Regex.match?(~r/^\+[1-9]\d{6,14}$/, n),
      do: {:ok, n},
      else: {:error, "Invalid phone number: use international format, e.g. +14155550123"}
  end

  def normalize(_), do: {:error, "Invalid phone number"}

  @doc "Sends a fresh code to `phone`."
  @spec request(String.t()) :: :ok | {:error, {String.t(), String.t()}}
  def request(phone) do
    now = DateTime.utc_now()

    with {:ok, mod} <- enabled_adapter(),
         {:ok, phone} <- normalize(phone) |> tag("InvalidPhone"),
         :ok <- not_too_soon(phone, now) do
      code = :rand.uniform(1_000_000) - 1
      code = code |> Integer.to_string() |> String.pad_leading(6, "0")

      Repo.insert_all(
        PhoneVerification,
        [
          %{
            phone: phone,
            code_hash: hash(phone, code),
            attempts: 0,
            expires_at: DateTime.add(now, @ttl_s),
            created_at: now
          }
        ],
        on_conflict: {:replace, [:code_hash, :attempts, :expires_at, :created_at]},
        conflict_target: :phone
      )

      case mod.send_code(phone, code, Config.get(:phone_verification)) do
        :ok ->
          :ok

        {:error, reason} ->
          {:error, {"UpstreamFailure", "Could not send SMS: #{inspect(reason)}"}}
      end
    end
  end

  @doc "Checks and spends a code. `:ok` when verification is off."
  @spec verify(String.t() | nil, String.t() | nil) :: :ok | {:error, {String.t(), String.t()}}
  def verify(phone, code) do
    cond do
      not required?() ->
        :ok

      not (is_binary(phone) and is_binary(code)) ->
        {:error, {"InvalidPhoneVerification", "Text message verification code required"}}

      true ->
        with {:ok, phone} <- normalize(phone) |> tag("InvalidPhoneVerification") do
          check(phone, code)
        end
    end
  end

  defp check(phone, code) do
    now = DateTime.utc_now()

    case Repo.get(PhoneVerification, phone) do
      %PhoneVerification{} = row ->
        cond do
          DateTime.compare(row.expires_at, now) != :gt or row.attempts >= @max_attempts ->
            Repo.delete_all(from(p in PhoneVerification, where: p.phone == ^phone))
            invalid()

          Plug.Crypto.secure_compare(row.code_hash, hash(phone, String.trim(code))) ->
            Repo.delete_all(from(p in PhoneVerification, where: p.phone == ^phone))
            :ok

          true ->
            Repo.update_all(from(p in PhoneVerification, where: p.phone == ^phone),
              inc: [attempts: 1]
            )

            invalid()
        end

      nil ->
        invalid()
    end
  end

  defp invalid,
    do:
      {:error, {"InvalidPhoneVerification", "Invalid or expired text message verification code"}}

  defp not_too_soon(phone, now) do
    case Repo.get(PhoneVerification, phone) do
      %PhoneVerification{created_at: at} ->
        if DateTime.diff(now, at) < @resend_after_s,
          do:
            {:error,
             {"RateLimitExceeded", "A code was sent to this number less than a minute ago"}},
          else: :ok

      nil ->
        :ok
    end
  end

  defp hash(phone, code),
    do: :crypto.mac(:hmac, :sha256, Config.jwt_secret(), phone <> ":" <> code)

  defp tag({:ok, _} = ok, _), do: ok
  defp tag({:error, msg}, name), do: {:error, {name, msg}}
end
