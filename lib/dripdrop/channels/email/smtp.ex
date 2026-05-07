defmodule DripDrop.Channels.Email.SMTP do
  @moduledoc """
  SMTP email provider backed by Swoosh.

  The provider sends through `Swoosh.Adapters.SMTP` using relay credentials
  configured on the channel adapter.
  """

  use DripDrop.Channels.Provider, required_credentials: [:relay]

  alias DripDrop.Channels.Email.SwooshDelivery

  @impl DripDrop.Channel
  def deliver(step, enrollment, adapter) do
    config =
      SwooshDelivery.config(adapter, Swoosh.Adapters.SMTP, [
        :relay,
        :username,
        :password,
        :port,
        :ssl,
        :tls,
        :auth,
        :retries,
        :no_mx_lookups,
        :dkim
      ])

    SwooshDelivery.deliver(step, enrollment, adapter, config)
  end
end
