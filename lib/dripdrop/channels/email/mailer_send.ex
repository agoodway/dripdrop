defmodule DripDrop.Channels.Email.MailerSend do
  @moduledoc """
  MailerSend email provider backed by Swoosh.

  The provider sends through `Swoosh.Adapters.Mailersend` and verifies inbound
  webhook requests with the configured MailerSend signature secret.
  """

  use DripDrop.Channels.Provider, required_credentials: [:api_key]

  alias DripDrop.Channels.Email.MailerSend.WebhookHandler
  alias DripDrop.Channels.Email.SwooshDelivery
  alias DripDrop.Channels.Helpers
  alias DripDrop.WebhookRequest

  @impl DripDrop.Channel
  def deliver(step, enrollment, adapter) do
    config = SwooshDelivery.config(adapter, Swoosh.Adapters.Mailersend, [:api_key, :base_url])
    SwooshDelivery.deliver(step, enrollment, adapter, config)
  end

  @impl DripDrop.Channel
  def webhook_routes(_adapter),
    do: [{:post, "/mailersend/:adapter_id", WebhookHandler}]

  @impl DripDrop.Channel
  def verify_signature(adapter, request) do
    secret = Helpers.credential(adapter, :webhook_secret) || Helpers.credential(adapter, :api_key)
    signature = WebhookRequest.header(request, "signature")

    if Helpers.hmac_sha256_verify(secret, WebhookRequest.body(request), to_string(signature)) do
      # MailerSend does not currently send a timestamp header, so replay
      # protection here relies on the unique `(provider, provider_event_id)`
      # constraint on `message_events` (see v01_up.sql:342). Duplicate
      # deliveries within the cluster's retention window are rejected at the
      # database level on insert. Replay across longer windows still possible.
      :ok
    else
      {:error, :invalid_signature}
    end
  end
end
