defmodule Aerox.Services do
  @moduledoc """
  Which services are enabled on this node (DESIGN §2). Read at boot by the
  supervision tree and per request by `AeroxWeb.Plugs.ServiceEnabled`.
  """

  @all [:pds, :plc, :relay, :appview, :labeler, :jetstream]

  @type service :: :pds | :plc | :relay | :appview | :labeler | :jetstream

  @spec all() :: [service]
  def all, do: @all

  @spec enabled() :: [service]
  def enabled do
    :aerox
    |> Application.get_env(:services, @all)
    |> Enum.filter(&(&1 in @all))
  end

  @spec enabled?(service) :: boolean
  def enabled?(service), do: service in enabled()
end
