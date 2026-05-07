defmodule DripDrop.ShortLinks.GoodAnalytics do
  @moduledoc """
  Short-link adapter for in-process GoodAnalytics integration.
  """

  @behaviour DripDrop.ShortLinks.Adapter

  alias DripDrop.ShortLinks.Result

  @impl DripDrop.ShortLinks.Adapter
  def create_link(request, opts) do
    if Code.ensure_loaded?(GoodAnalytics) and function_exported?(GoodAnalytics, :create_link, 1) do
      request
      |> to_good_analytics_args(opts)
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      |> then(&apply(GoodAnalytics, :create_link, [&1]))
      |> normalize_result()
    else
      {:error, %{kind: :permanent, reason: :good_analytics_not_loaded}}
    end
  end

  defp to_good_analytics_args(request, opts) do
    %{
      workspace_id: Keyword.get(opts, :workspace_id),
      domain: request.domain,
      key: request.key || String.slice(request.idempotency_key, 0, 12),
      url: request.destination_url,
      link_type: "campaign",
      utm_source: Map.get(request.utm, "source", "dripdrop"),
      utm_medium: Map.get(request.utm, "medium", to_string(request.channel || "")),
      utm_campaign: Map.get(request.utm, "campaign", request.sequence_key),
      utm_content: Map.get(request.utm, "content", request.step_key),
      external_id: request.idempotency_key,
      metadata: request.metadata
    }
  end

  defp normalize_result({:ok, %{short_url: short_url} = response}) do
    {:ok, %Result{short_url: short_url, response: response}}
  end

  defp normalize_result({:ok, %{"short_url" => short_url} = response}) do
    {:ok, %Result{short_url: short_url, response: response}}
  end

  defp normalize_result({:error, reason}), do: {:error, %{kind: :permanent, reason: reason}}
end
