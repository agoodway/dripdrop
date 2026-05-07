defmodule DripDrop.Channels.Email.SendGrid do
  @moduledoc """
  SendGrid email provider backed by Swoosh.

  The provider sends through `Swoosh.Adapters.Sendgrid` and verifies Event
  Webhook signatures using SendGrid's ECDSA public-key scheme.
  """

  use DripDrop.Channels.Provider, required_credentials: [:api_key]

  alias DripDrop.Channels.Email.SendGrid.WebhookHandler
  alias DripDrop.Channels.Email.SwooshDelivery
  alias DripDrop.Channels.Helpers
  alias DripDrop.WebhookRequest

  @impl DripDrop.Channel
  def deliver(step, enrollment, adapter) do
    config = SwooshDelivery.config(adapter, Swoosh.Adapters.Sendgrid, [:api_key, :base_url])
    SwooshDelivery.deliver(step, enrollment, adapter, config)
  end

  @impl DripDrop.Channel
  def webhook_routes(_adapter),
    do: [{:post, "/sendgrid/:adapter_id", WebhookHandler}]

  @impl DripDrop.Channel
  def verify_signature(adapter, request) do
    public_key = Helpers.credential(adapter, :webhook_public_key)
    timestamp = WebhookRequest.header(request, "x-twilio-email-event-webhook-timestamp")
    signature = WebhookRequest.header(request, "x-twilio-email-event-webhook-signature")
    payload = "#{timestamp}#{WebhookRequest.body(request)}"

    with {:ok, key} <- decode_base64(public_key),
         {:ok, signature} <- decode_base64(signature),
         true <- verify_ecdsa(payload, signature, key),
         :ok <- check_replay_window(timestamp, adapter, request) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_signature}
    end
  end

  defp check_replay_window(timestamp, adapter, request) do
    if Helpers.within_skew?(timestamp, replay_skew_seconds()) do
      :ok
    else
      :telemetry.execute([:dripdrop, :webhook, :replay_window], %{count: 1}, %{
        provider: :send_grid,
        adapter_id: Map.get(adapter, :id),
        timestamp: timestamp,
        url: WebhookRequest.url(request)
      })

      {:error, :replay_window}
    end
  end

  defp replay_skew_seconds,
    do: Application.get_env(:dripdrop, :webhook_replay_skew_seconds, 300)

  defp decode_base64(nil), do: {:error, :missing_value}

  defp decode_base64(value) do
    case Base.decode64(value) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_base64}
    end
  end

  defp verify_ecdsa(payload, signature, key) do
    :crypto.verify(:ecdsa, :sha256, payload, signature, [key, :secp256r1])
  rescue
    ErlangError -> false
  end
end
