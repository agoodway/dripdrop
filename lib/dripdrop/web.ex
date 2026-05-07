defmodule DripDrop.Web do
  @moduledoc """
  Webhook route helpers for host applications.

  Host apps can enumerate provider-declared webhook routes for diagnostics or
  mount `DripDrop.Web.WebhookPlug` through the router macro in
  `DripDrop.Web.Router`.
  """

  alias DripDrop.ChannelAdapters

  @doc """
  Returns webhook routes exposed by active provider adapters.
  """
  @spec webhook_routes() :: [DripDrop.Channel.webhook_route()]
  defdelegate webhook_routes, to: ChannelAdapters
end
