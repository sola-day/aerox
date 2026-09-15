defmodule Aerox.PDS.SMS do
  @moduledoc "Delivery of a phone verification code (`Aerox.PDS.PhoneVerification`)."
  @callback send_code(phone :: String.t(), code :: String.t(), config :: keyword) ::
              :ok | {:error, term}
end

defmodule Aerox.PDS.SMS.Log do
  @moduledoc "Development and tests: the code goes to the log (and to `:notify`, a pid, when set)."
  @behaviour Aerox.PDS.SMS
  require Logger

  @impl true
  def send_code(phone, code, config) do
    Logger.info("sms: verification code for #{phone}: #{code}")
    if pid = config[:notify], do: send(pid, {:sms_code, phone, code})
    :ok
  end
end

defmodule Aerox.PDS.SMS.Twilio do
  @moduledoc """
  Twilio's Messages API: `POST /2010-04-01/Accounts/<sid>/Messages.json` with
  HTTP Basic `sid:auth_token` and form fields `To`, `From`, `Body`. Config:
  `account_sid`, `auth_token`, `from` (a number or messaging service in E.164).
  """
  @behaviour Aerox.PDS.SMS

  @impl true
  def send_code(phone, code, config) do
    sid = Keyword.fetch!(config, :account_sid)
    token = Keyword.fetch!(config, :auth_token)
    host = Aerox.PDS.Config.hostname()

    case Req.post("https://api.twilio.com/2010-04-01/Accounts/#{sid}/Messages.json",
           auth: {:basic, "#{sid}:#{token}"},
           form: [
             To: phone,
             From: Keyword.fetch!(config, :from),
             Body: "Your #{host} verification code is #{code}"
           ],
           retry: false,
           receive_timeout: 10_000
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
