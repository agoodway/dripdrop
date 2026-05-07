defmodule DripDrop.Channels.Email.Ms365 do
  @moduledoc """
  Microsoft 365 email provider backed by Microsoft Graph.

  The provider accepts a host-supplied token callback and posts a Graph
  `sendMail` request for the configured mailbox.
  """

  use DripDrop.Channels.Provider, required_credentials: [:token_callback, :user_email]

  alias DripDrop.Channels.Email.OAuthToken
  alias DripDrop.Channels.{Helpers, Payload}

  @impl DripDrop.Channel
  def deliver(step, enrollment, adapter) do
    with {:ok, access_token} <- OAuthToken.get(adapter, :ms365),
         payload <- Payload.get(step),
         user_email <- Helpers.credential(adapter, :user_email),
         {:ok, %{status: status, body: body}} when status in 200..299 <-
           Req.post(
             "https://graph.microsoft.com/v1.0/users/#{URI.encode_www_form(user_email)}/sendMail",
             Keyword.merge(
               [auth: {:bearer, access_token}, json: request_body(payload, enrollment)],
               Helpers.request_options(adapter)
             )
           ) do
      {:ok, %{provider_message_id: message_id(body), response: %{status: status, body: body}}}
    else
      {:ok, %{status: status, body: body}} when status in 500..599 or status == 429 ->
        {:error, %{kind: :temporary, reason: {:ms365, status, body}}}

      {:ok, %{status: status, body: body}} ->
        {:error, %{kind: :permanent, reason: {:ms365, status, body}}}

      {:error, {:token_callback, :revoked}} ->
        {:error, %{kind: :permanent, reason: {:token_callback, :revoked}}}

      {:error, reason} ->
        {:error, %{kind: :temporary, reason: reason}}
    end
  end

  defp request_body(payload, enrollment) do
    %{
      message:
        %{
          subject: Map.get(payload, :subject),
          body: body(payload),
          toRecipients:
            recipients(Map.get(payload, :to) || Helpers.recipient(enrollment, payload, :email)),
          ccRecipients: recipients(Map.get(payload, :cc)),
          bccRecipients: recipients(Map.get(payload, :bcc)),
          replyTo: recipients(Map.get(payload, :reply_to)),
          internetMessageHeaders: headers(payload)
        }
        |> Helpers.drop_nil_values(),
      saveToSentItems: Map.get(payload, :save_to_sent_items, true)
    }
  end

  defp body(%{html: html}) when is_binary(html), do: %{contentType: "HTML", content: html}
  defp body(%{text: text}) when is_binary(text), do: %{contentType: "Text", content: text}
  defp body(_payload), do: %{contentType: "Text", content: ""}

  defp recipients(nil), do: []

  defp recipients(recipients) when is_list(recipients),
    do: Enum.map(recipients, &recipient/1)

  defp recipients(recipient), do: [recipient(recipient)]

  defp recipient({name, address}), do: %{emailAddress: %{name: name, address: address}}

  defp recipient(%{"name" => name, "email" => address}),
    do: %{emailAddress: %{name: name, address: address}}

  defp recipient(%{name: name, email: address}),
    do: %{emailAddress: %{name: name, address: address}}

  defp recipient(address), do: %{emailAddress: %{address: to_string(address)}}

  defp headers(payload) do
    payload
    |> Map.get(:headers, %{})
    |> normalize_headers()
    |> maybe_put_idempotency_header(payload)
  end

  defp normalize_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {key, value} -> %{name: to_string(key), value: to_string(value)} end)
  end

  defp normalize_headers(_headers), do: []

  defp maybe_put_idempotency_header(headers, %{idempotency_key: key}) when is_binary(key),
    do: [%{name: "X-DripDrop-Idempotency-Key", value: key} | headers]

  defp maybe_put_idempotency_header(headers, _payload), do: headers

  defp message_id(%{"id" => id}), do: id
  defp message_id(%{"internetMessageId" => id}), do: id
  defp message_id(_body), do: nil
end
