defmodule DripDrop.Channels.Email.Postmark do
  @moduledoc """
  Postmark email provider backed by Swoosh.

  The provider sends through `Swoosh.Adapters.Postmark` and supports a basic
  authentication guard for Postmark webhook endpoints.
  """

  use DripDrop.Channels.Provider, required_credentials: [:api_key]

  alias DripDrop.Channels.Email.Postmark.WebhookHandler
  alias DripDrop.Channels.Email.SwooshDelivery
  alias DripDrop.Channels.Helpers
  alias DripDrop.WebhookRequest

  @impl DripDrop.Channel
  def deliver(step, enrollment, adapter) do
    config = SwooshDelivery.config(adapter, Swoosh.Adapters.Postmark, [:api_key, :base_url])
    SwooshDelivery.deliver(step, enrollment, adapter, config)
  end

  @impl DripDrop.Channel
  def webhook_routes(_adapter),
    do: [{:post, "/postmark/:adapter_id", WebhookHandler}]

  @impl DripDrop.Channel
  def verify_signature(adapter, request) do
    secret = Helpers.credential(adapter, :webhook_secret)
    signature = WebhookRequest.header(request, "x-postmark-signature")

    if not is_nil(secret) and not is_nil(signature) do
      verify_hmac(secret, WebhookRequest.body(request), to_string(signature))
    else
      verify_basic_auth_fallback(adapter, request)
    end
  end

  defp verify_hmac(secret, body, signature_b64) do
    expected =
      :hmac
      |> :crypto.mac(:sha256, secret, body)
      |> Base.encode64()

    if Helpers.secure_compare(expected, signature_b64) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp verify_basic_auth_fallback(adapter, request) do
    expected = Helpers.credential(adapter, :webhook_basic_auth)

    case WebhookRequest.header(request, "authorization") do
      "Basic " <> encoded -> verify_basic_auth(encoded, expected)
      _missing -> {:error, :missing_authorization}
    end
  end

  defp verify_basic_auth(_encoded, nil), do: {:error, :missing_webhook_basic_auth}

  defp verify_basic_auth(encoded, expected) do
    with {:ok, decoded} <- Base.decode64(encoded),
         true <- Helpers.secure_compare(decoded, expected) do
      :ok
    else
      _invalid -> {:error, :invalid_signature}
    end
  end
end
