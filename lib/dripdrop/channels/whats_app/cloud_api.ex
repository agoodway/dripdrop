defmodule DripDrop.Channels.WhatsApp.CloudAPI do
  @moduledoc """
  WhatsApp Cloud API channel provider for sending templated or text messages.
  """

  use DripDrop.Channels.Provider, required_credentials: [:access_token, :phone_number_id]

  alias DripDrop.Channels.Helpers
  alias DripDrop.Channels.Payload

  @impl DripDrop.Channel
  def deliver(step, _enrollment, adapter) do
    payload = Payload.get(step)
    phone_number_id = credential(adapter, "phone_number_id")
    token = credential(adapter, "access_token")

    body =
      payload
      |> Map.put_new(:messaging_product, "whatsapp")
      |> Map.put_new(:recipient_type, "individual")
      |> Map.put_new(:type, "text")

    opts =
      [json: body, auth: {:bearer, token}]
      |> Keyword.merge(Helpers.request_options(adapter))

    case Req.post("https://graph.facebook.com/v23.0/#{phone_number_id}/messages", opts) do
      {:ok, %{status: status, body: %{"messages" => [%{"id" => message_id} | _]} = response}}
      when status in 200..299 ->
        {:ok, %{provider_message_id: message_id, response: response}}

      {:ok, %{status: status, body: response}} when status in 500..599 or status == 429 ->
        {:error, %{kind: :temporary, reason: {:whatsapp, status, response}}}

      {:ok, %{status: status, body: response}} ->
        {:error, %{kind: :permanent, reason: {:whatsapp, status, response}}}

      {:error, reason} ->
        {:error, %{kind: :temporary, reason: reason}}
    end
  end

  defp credential(adapter, key), do: Helpers.credential(adapter, key)
end
