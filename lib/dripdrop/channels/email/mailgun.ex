defmodule DripDrop.Channels.Email.Mailgun do
  @moduledoc """
  Mailgun email provider backed by Swoosh.

  The provider sends through `Swoosh.Adapters.Mailgun` and verifies inbound
  Mailgun webhook signatures with the configured webhook signing key or API key.
  """

  use DripDrop.Channels.Provider, required_credentials: [:api_key, :domain]

  alias DripDrop.Channels.Email.Mailgun.WebhookHandler
  alias DripDrop.Channels.Email.SwooshDelivery
  alias DripDrop.Channels.Helpers
  alias DripDrop.WebhookRequest

  @impl DripDrop.Channel
  def deliver(step, enrollment, adapter) do
    config =
      SwooshDelivery.config(adapter, Swoosh.Adapters.Mailgun, [:api_key, :domain, :base_url])

    SwooshDelivery.deliver(step, enrollment, adapter, config)
  end

  @impl DripDrop.Channel
  def webhook_routes(_adapter),
    do: [{:post, "/mailgun/:adapter_id", WebhookHandler}]

  @impl DripDrop.Channel
  def verify_signature(adapter, request) do
    signing_key =
      Helpers.credential(adapter, :webhook_signing_key) || Helpers.credential(adapter, :api_key)

    timestamp = WebhookRequest.param(request, ["signature", "timestamp"])
    token = WebhookRequest.param(request, ["signature", "token"])
    signature = WebhookRequest.param(request, ["signature", "signature"])

    with true <-
           Helpers.hmac_sha256_verify(signing_key, "#{timestamp}#{token}", to_string(signature)),
         :ok <- check_replay_window(timestamp, adapter, request) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_signature}
    end
  end

  defp check_replay_window(timestamp, adapter, request) do
    if Helpers.within_skew?(timestamp, replay_skew_seconds()) do
      :ok
    else
      :telemetry.execute([:dripdrop, :webhook, :replay_window], %{count: 1}, %{
        provider: :mailgun,
        adapter_id: Map.get(adapter, :id),
        timestamp: timestamp,
        url: WebhookRequest.url(request)
      })

      {:error, :replay_window}
    end
  end

  defp replay_skew_seconds,
    do: Application.get_env(:dripdrop, :webhook_replay_skew_seconds, 300)
end
