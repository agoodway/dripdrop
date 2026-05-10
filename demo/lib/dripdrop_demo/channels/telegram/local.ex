defmodule DripdropDemo.Channels.Telegram.Local do
  @moduledoc """
  Local Telegram provider for the demo application.

  It exercises DripDrop's Telegram channel shape without calling Telegram's
  network API during local demos.
  """

  use DripDrop.Channels.Provider

  alias DripDrop.Channels.Payload

  @impl DripDrop.Channel
  def deliver(step, _enrollment, adapter) do
    payload = Payload.get(step)
    chat_id = Map.get(payload, :chat_id) || get_in(adapter.credentials || %{}, ["chat_id"])

    response = %{
      provider: "local",
      chat_id: chat_id,
      text: Map.get(payload, :text),
      parse_mode: Map.get(payload, :parse_mode)
    }

    Phoenix.PubSub.broadcast(
      DripdropDemo.PubSub,
      "demo:telegram",
      {"telegram.message.sent", Map.put(response, :received_at, DateTime.utc_now())}
    )

    {:ok, %{provider_message_id: "local-telegram-" <> Ecto.UUID.generate(), response: response}}
  end
end
