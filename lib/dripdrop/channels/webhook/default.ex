defmodule DripDrop.Channels.Webhook.Default do
  @moduledoc """
  Generic signed HTTP webhook channel provider.
  """

  use DripDrop.Channels.Provider, required_credentials: [:url, :secret]

  alias DripDrop.Channels.{Helpers, Payload}
  alias DripDrop.Channels.Webhook.Standard
  alias DripDrop.Helpers, as: SharedHelpers
  alias DripDrop.Hooks.URLGuard

  @impl DripDrop.Channel
  def deliver(step, _enrollment, adapter) do
    payload = Payload.get(step)
    url = Map.get(payload, :url) || Helpers.credential(adapter, :url)

    req_options = Helpers.request_options(adapter)

    case URLGuard.validate(url, req_options: req_options) do
      :ok ->
        method = SharedHelpers.http_method(Map.get(payload, :method, :post), :post)
        headers = Map.get(payload, :headers, %{})
        body = payload |> Map.get(:body) |> then(&Standard.payload(payload, &1))

        method
        |> Standard.request_opts(url, body, headers, adapter)
        |> Keyword.merge(req_options)
        |> Req.request()
        |> Helpers.provider_result(:http_status, fn _body -> nil end)

      {:error, reason} ->
        :telemetry.execute([:dripdrop, :webhook, :url_blocked], %{count: 1}, %{
          url: url,
          reason: reason,
          tenant_key: adapter.tenant_key
        })

        {:error, %{kind: :permanent, reason: {:url_blocked, reason}}}
    end
  end
end
