defmodule AeroxWeb.XRPC.Error do
  @moduledoc """
  An XRPC error response (upstream `xrpc-server` error classes): an HTTP
  status, the error `name` clients switch on, and a message. Raised from
  controllers or returned as `{:error, %Error{}}`; `AeroxWeb.Plugs.XRPCError`
  renders both as `{"error": name, "message": message}`.
  """
  defexception [:status, :name, :message]

  @type t :: %__MODULE__{status: pos_integer, name: String.t(), message: String.t()}

  def invalid_request(message, name \\ "InvalidRequest"),
    do: %__MODULE__{status: 400, name: name, message: message}

  def auth_required(message \\ "Authentication Required", name \\ "AuthenticationRequired"),
    do: %__MODULE__{status: 401, name: name, message: message}

  def forbidden(message \\ "Forbidden", name \\ "Forbidden"),
    do: %__MODULE__{status: 403, name: name, message: message}

  def not_found(message \\ "Not Found", name \\ "NotFound"),
    do: %__MODULE__{status: 404, name: name, message: message}

  def rate_limited,
    do: %__MODULE__{status: 429, name: "RateLimitExceeded", message: "Rate Limit Exceeded"}

  def internal(message \\ "Internal Server Error"),
    do: %__MODULE__{status: 500, name: "InternalServerError", message: message}

  def not_implemented(message \\ "Method Not Implemented"),
    do: %__MODULE__{status: 501, name: "MethodNotImplemented", message: message}

  def upstream_failure(message \\ "Upstream Failure"),
    do: %__MODULE__{status: 502, name: "UpstreamFailure", message: message}

  def upstream_timeout(message \\ "Upstream Timeout"),
    do: %__MODULE__{status: 504, name: "UpstreamTimeout", message: message}

  @doc "Renders the JSON body."
  def body(%__MODULE__{name: name, message: message}),
    do: %{"error" => name, "message" => message}
end
