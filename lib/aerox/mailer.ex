defmodule Aerox.Mailer do
  @moduledoc "The Swoosh mailer, its own boundary so services can send mail without depending on the application root."
  use Boundary, top_level?: true, deps: []
  use Swoosh.Mailer, otp_app: :aerox
end
