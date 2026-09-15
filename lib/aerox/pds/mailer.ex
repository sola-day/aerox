defmodule Aerox.PDS.Mailer do
  @moduledoc """
  Email (DESIGN §18.1): the five token purposes upstream defines, plain
  text and HTML, delivered asynchronously through Oban so an API response
  never waits on the mail provider. `Aerox.Mailer` is the Swoosh mailer.
  """
  import Swoosh.Email

  @subjects %{
    "confirm_email" => "Email Confirmation",
    "update_email" => "Email Update Requested",
    "reset_password" => "Password Reset Requested",
    "delete_account" => "Account Deletion Requested",
    "plc_operation" => "PLC Update Operation Requested"
  }

  @doc "Enqueues delivery of a token mail."
  @spec send_token(String.t(), String.t(), String.t(), keyword) ::
          {:ok, Oban.Job.t()} | {:error, term}
  def send_token(purpose, to, token, opts \\ []) when is_map_key(@subjects, purpose) do
    job =
      __MODULE__.Deliver.new(%{
        purpose: purpose,
        to: to,
        token: token,
        handle: Keyword.get(opts, :handle)
      })

    # the instance name comes first: piping the changeset in made it Oban.insert(changeset, name)
    Oban.insert(Aerox.PDS.Oban, job)
  end

  @doc "A plain-text message from the admin (`com.atproto.admin.sendEmail`), delivered synchronously."
  def send_plain(to, subject, text) do
    Swoosh.Email.new()
    |> Swoosh.Email.to(to)
    |> Swoosh.Email.from(from_address())
    |> Swoosh.Email.subject(subject)
    |> Swoosh.Email.text_body(text)
    |> Aerox.Mailer.deliver()
  end

  defp from_address do
    service = Aerox.PDS.Config.hostname()
    {service, Aerox.PDS.Config.get(:from_email) || "noreply@#{service}"}
  end

  @doc "Builds the Swoosh email for a purpose."
  @spec build(String.t(), String.t(), String.t(), String.t() | nil) :: Swoosh.Email.t()
  def build(purpose, to, token, handle) do
    service = Aerox.PDS.Config.hostname()

    new()
    |> to(to)
    |> from(from_address())
    |> subject(@subjects[purpose])
    |> text_body(text(purpose, token, handle, service))
    |> html_body(
      "<p>" <>
        (text(purpose, token, handle, service)
         |> Phoenix.HTML.html_escape()
         |> Phoenix.HTML.safe_to_string()
         |> String.replace("\n", "<br>")) <> "</p>"
    )
  end

  defp text("confirm_email", token, _handle, service),
    do:
      "#{token} is your verification code.\n\nConfirm your email address on #{service} by entering this code. If you did not request this, you can ignore this message."

  defp text("update_email", token, _handle, service),
    do:
      "#{token} is your code to change the email address on your #{service} account.\n\nIf you did not request this, you can ignore this message."

  defp text("reset_password", token, handle, service),
    do:
      "A password reset was requested for #{handle || "your account"} on #{service}.\n\nYour reset code is #{token}. It expires in 15 minutes. If you did not request this, you can ignore this message."

  defp text("delete_account", token, _handle, service),
    do:
      "A request was made to delete your #{service} account.\n\nYour confirmation code is #{token}. It expires in 15 minutes. If you did not request this, change your password now."

  defp text("plc_operation", token, _handle, service),
    do:
      "A request was made to update the identity document of your #{service} account.\n\nYour confirmation code is #{token}. It expires in 15 minutes. If you did not request this, you can ignore this message."

  defmodule Deliver do
    @moduledoc "Oban worker: renders and sends one token mail, retrying with back-off."
    use Oban.Worker, queue: :mail, max_attempts: 8

    @impl true
    def perform(%Oban.Job{args: %{"purpose" => purpose, "to" => to, "token" => token} = args}) do
      email = Aerox.PDS.Mailer.build(purpose, to, token, args["handle"])

      case Aerox.Mailer.deliver(email) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
