defmodule DripDrop.ShortLinks.Webhook do
  @moduledoc """
  Short-link adapter that calls a host-owned HTTP endpoint.
  """

  @behaviour DripDrop.ShortLinks.Adapter

  alias DripDrop.Hooks.URLGuard
  alias DripDrop.ShortLinks.Result

  @impl DripDrop.ShortLinks.Adapter
  def create_link(request, opts) do
    endpoint = Keyword.fetch!(opts, :endpoint)
    headers = Keyword.get(opts, :headers, [])
    req_options = Keyword.get(opts, :req_options, [])

    case URLGuard.validate(endpoint, req_options: req_options) do
      :ok ->
        request_options =
          Keyword.merge([json: Map.from_struct(request), headers: headers], req_options)

        do_post(endpoint, request_options)

      {:error, reason} ->
        :telemetry.execute([:dripdrop, :short_links, :url_blocked], %{count: 1}, %{
          endpoint: endpoint,
          reason: reason
        })

        {:error, %{kind: :permanent, reason: {:url_blocked, reason}}}
    end
  end

  defp do_post(endpoint, request_options) do
    case Req.post(endpoint, request_options) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, %Result{short_url: body["short_url"] || body["shortUrl"], response: body}}

      {:ok, %{status: status, body: body}} when status in 500..599 or status == 429 ->
        {:error, %{kind: :temporary, reason: {:webhook, status, body}}}

      {:ok, %{status: status, body: body}} ->
        {:error, %{kind: :permanent, reason: {:webhook, status, body}}}

      {:error, reason} ->
        {:error, %{kind: :temporary, reason: reason}}
    end
  end
end
