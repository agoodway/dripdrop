defmodule DripDrop.Channels.Slack.Webhook do
  @moduledoc """
  Slack incoming-webhook channel provider.
  """

  use DripDrop.Channels.Provider, required_credentials: [:url]

  alias DripDrop.Channels.{Helpers, Payload}
  alias DripDrop.Hooks.URLGuard

  @impl DripDrop.Channel
  def deliver(step, _enrollment, adapter) do
    payload = Payload.get(step)
    body = payload |> Map.take([:channel, :text, :blocks]) |> Helpers.drop_nil_values()
    url = Helpers.credential(adapter, :url)
    req_options = Helpers.request_options(adapter)

    case URLGuard.validate(url, req_options: req_options) do
      :ok ->
        url
        |> Req.post(Keyword.merge([json: body], req_options))
        |> Helpers.provider_result(:slack, fn _body -> nil end)

      {:error, reason} ->
        :telemetry.execute([:dripdrop, :slack, :url_blocked], %{count: 1}, %{
          url: url,
          reason: reason,
          tenant_key: adapter.tenant_key
        })

        {:error, %{kind: :permanent, reason: {:url_blocked, reason}}}
    end
  end
end
