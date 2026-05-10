defmodule DripDrop.Channels.Email.Local do
  @moduledoc """
  Local development email provider backed by `Swoosh.Adapters.Local`.
  """

  use DripDrop.Channels.Provider

  alias DripDrop.Channels.Email.SwooshDelivery

  @impl DripDrop.Channel
  def deliver(step, enrollment, adapter) do
    config = SwooshDelivery.config(adapter, Swoosh.Adapters.Local, [])
    SwooshDelivery.deliver(step, enrollment, adapter, config)
  end
end
