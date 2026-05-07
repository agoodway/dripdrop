defmodule DripDrop.Channels.PubSub.PhoenixPubSub do
  @moduledoc """
  Phoenix PubSub channel provider for in-app dispatch fan-out.
  """

  use DripDrop.Channels.Provider, required_credentials: [:pubsub, :topic]

  alias DripDrop.Channels.Payload

  @impl DripDrop.Channel
  def deliver(step, _enrollment, adapter) do
    payload = Payload.get(step)
    pubsub = credential(adapter, "pubsub")
    topic = Map.get(payload, :topic) || credential(adapter, "topic")
    event = Map.get(payload, :event, "dripdrop.message")
    message = Map.get(payload, :payload, payload)

    case Phoenix.PubSub.broadcast(pubsub, topic, {event, message}) do
      :ok -> {:ok, %{provider_message_id: nil, response: %{topic: topic, event: event}}}
      {:error, reason} -> {:error, %{kind: :temporary, reason: reason}}
    end
  end

  defp credential(adapter, key),
    do: DripDrop.Helpers.fetch_string_or_atom_key(adapter.credentials, key)
end
