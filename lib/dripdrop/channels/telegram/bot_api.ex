defmodule DripDrop.Channels.Telegram.BotAPI do
  @moduledoc """
  Telegram Bot API channel provider for sending chat messages.
  """

  use DripDrop.Channels.Provider, required_credentials: [:bot_token, :chat_id]

  alias DripDrop.Channels.{Helpers, Payload}

  @impl DripDrop.Channel
  def deliver(step, _enrollment, adapter) do
    payload = Payload.get(step)
    token = Helpers.credential(adapter, :bot_token)

    body =
      %{
        chat_id: Map.get(payload, :chat_id) || Helpers.credential(adapter, :chat_id),
        text: Map.get(payload, :text),
        parse_mode: Map.get(payload, :parse_mode)
      }
      |> Helpers.drop_nil_values()

    opts = Keyword.merge([json: body], Helpers.request_options(adapter))

    case Req.post("https://api.telegram.org/bot#{token}/sendMessage", opts) do
      {:ok, %{status: status, body: %{"ok" => true, "result" => result}}}
      when status in 200..299 ->
        {:ok, %{provider_message_id: to_string(result["message_id"]), response: result}}

      {:ok, %{status: status, body: body}} when status in 500..599 or status == 429 ->
        {:error, %{kind: :temporary, reason: {:telegram, status, body}}}

      {:ok, %{status: status, body: body}} ->
        {:error, %{kind: :permanent, reason: {:telegram, status, body}}}

      {:error, reason} ->
        {:error, %{kind: :temporary, reason: reason}}
    end
  end
end
