defmodule DripDrop.Channels.Email.Gmail do
  @moduledoc """
  Gmail API email provider.

  The provider accepts a host-supplied token callback, builds an RFC 5322
  message, encodes it with base64url, and sends through
  `users.messages.send`.
  """

  use DripDrop.Channels.Provider, required_credentials: [:token_callback, :user_email]

  alias DripDrop.Channels.Email.{MIME, OAuthToken}
  alias DripDrop.Channels.{Helpers, Payload}

  @impl DripDrop.Channel
  def deliver(step, enrollment, adapter) do
    with {:ok, access_token} <- OAuthToken.get(adapter, :gmail),
         payload <- Payload.get(step),
         raw <- payload |> MIME.rfc5322(enrollment, adapter) |> Base.url_encode64(padding: false),
         {:ok, %{status: status, body: body}} when status in 200..299 <-
           Req.post(
             "https://gmail.googleapis.com/gmail/v1/users/me/messages/send",
             Keyword.merge(
               [auth: {:bearer, access_token}, json: %{raw: raw}],
               Helpers.request_options(adapter)
             )
           ) do
      {:ok, %{provider_message_id: Map.get(body, "id"), response: %{status: status, body: body}}}
    else
      {:ok, %{status: status, body: body}} when status in 500..599 or status == 429 ->
        {:error, %{kind: :temporary, reason: {:gmail, status, body}}}

      {:ok, %{status: status, body: body}} ->
        {:error, %{kind: :permanent, reason: {:gmail, status, body}}}

      {:error, {:token_callback, :revoked}} ->
        {:error, %{kind: :permanent, reason: {:token_callback, :revoked}}}

      {:error, reason} ->
        {:error, %{kind: :temporary, reason: reason}}
    end
  end
end
