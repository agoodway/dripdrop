defmodule DripDrop.Channels.SMS.Twilio do
  @moduledoc """
  Twilio SMS provider.

  The provider sends through Twilio's Messages API, passes request idempotency
  when present, and verifies Twilio status callbacks with the configured auth
  token.
  """

  use DripDrop.Channels.Provider, required_credentials: [:account_sid, :auth_token, :from]

  alias DripDrop.Channels.{Helpers, Payload}
  alias DripDrop.Channels.SMS.Twilio.WebhookHandler
  alias DripDrop.WebhookRequest

  @impl DripDrop.Channel
  def deliver(step, enrollment, adapter) do
    payload = Payload.get(step)
    account_sid = Helpers.credential(adapter, :account_sid)
    auth_token = Helpers.credential(adapter, :auth_token)

    headers =
      payload
      |> Map.get(:idempotency_key)
      |> idempotency_headers()

    form = [
      To: Helpers.recipient(enrollment, payload, :sms),
      From: Map.get(payload, :from) || Helpers.credential(adapter, :from),
      Body: Map.get(payload, :body)
    ]

    "https://api.twilio.com/2010-04-01/Accounts/#{account_sid}/Messages.json"
    |> Req.post(
      Keyword.merge(
        [auth: {:basic, "#{account_sid}:#{auth_token}"}, form: form, headers: headers],
        Helpers.request_options(adapter)
      )
    )
    |> Helpers.provider_result(:twilio, &message_sid/1)
  end

  defp idempotency_headers(nil), do: []
  defp idempotency_headers(key), do: [{"Idempotency-Key", key}]

  @impl DripDrop.Channel
  def webhook_routes(_adapter), do: [{:post, "/twilio/:adapter_id", WebhookHandler}]

  @impl DripDrop.Channel
  def verify_signature(adapter, request) do
    auth_token = Helpers.credential(adapter, :auth_token)
    signature = WebhookRequest.header(request, "x-twilio-signature")

    expected =
      request
      |> twilio_signature_payload()
      |> then(&:crypto.mac(:hmac, :sha, auth_token, &1))
      |> Base.encode64()

    # Twilio doesn't send a webhook timestamp header, so replay protection
    # relies on the unique `(provider, provider_event_id)` index on
    # `message_events` keyed by `MessageSid` — a duplicate delivery is
    # rejected at the database layer on insert. Replays across the retention
    # window are still possible until the row ages out.
    if Helpers.secure_compare(expected, to_string(signature)),
      do: :ok,
      else: {:error, :invalid_signature}
  end

  defp twilio_signature_payload(request) do
    params =
      request
      |> WebhookRequest.params()
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)

    Enum.reduce(params, WebhookRequest.url(request) || "", fn {key, value}, acc ->
      acc <> to_string(key) <> to_string(value)
    end)
  end

  defp message_sid(%{"sid" => sid}), do: sid
  defp message_sid(_body), do: nil
end
