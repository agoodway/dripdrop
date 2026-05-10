defmodule DripDrop.Channels.SMS.Local do
  @moduledoc """
  Local development SMS provider.

  It validates and renders the same DripDrop SMS payload shape as networked SMS
  providers, then returns a synthetic provider message id without making an
  external request.
  """

  use DripDrop.Channels.Provider

  alias DripDrop.Channels.{Helpers, Payload}

  @impl DripDrop.Channel
  def deliver(step, enrollment, adapter) do
    payload = Payload.get(step)
    to = Helpers.recipient(enrollment, payload, :sms)
    from = Map.get(payload, :from) || Helpers.credential(adapter, :from)
    body = Map.get(payload, :body)

    {:ok,
     %{
       provider_message_id: local_message_id(),
       response: %{
         provider: "local",
         to: to,
         from: from,
         body: body
       }
     }}
  end

  defp local_message_id do
    "local-sms-" <> Ecto.UUID.generate()
  end
end
