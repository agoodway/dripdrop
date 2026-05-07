defmodule DripDrop.ShortLinks.Config do
  @moduledoc """
  Resolves effective short-link configuration.
  """

  alias DripDrop.ShortLinks.{GoodAnalytics, None, Webhook}
  alias DripDrop.ShortLinks.Module, as: ModuleAdapter

  @defaults [
    enabled: false,
    provider: None,
    exclude_patterns: [],
    on_error: :fail
  ]

  @doc """
  Resolves effective short-link configuration from app, tenant, sequence, and step settings.
  """
  @spec resolve(map() | nil, map() | nil, keyword()) :: keyword()
  def resolve(sequence, step, tenant_config \\ []) do
    @defaults
    |> Keyword.merge(Application.get_env(:dripdrop, :short_links, []))
    |> Keyword.merge(tenant_config)
    |> merge_map(short_link_config(sequence, :metadata))
    |> merge_map(short_link_config(step, :config))
    |> normalize()
  end

  @doc """
  Returns URL exclusion patterns from resolved short-link configuration.
  """
  @spec exclude_patterns(keyword()) :: [Regex.t() | binary()]
  def exclude_patterns(config), do: Keyword.get(config, :exclude_patterns, [])

  defp short_link_config(%{metadata: %{"short_links" => config}}, :metadata), do: config
  defp short_link_config(%{metadata: %{short_links: config}}, :metadata), do: config
  defp short_link_config(%{"metadata" => %{"short_links" => config}}, :metadata), do: config
  defp short_link_config(%{config: %{"short_links" => config}}, :config), do: config
  defp short_link_config(%{config: %{short_links: config}}, :config), do: config
  defp short_link_config(%{"config" => %{"short_links" => config}}, :config), do: config
  defp short_link_config(_source, _field), do: %{}

  defp merge_map(config, overrides) when is_map(overrides) do
    Keyword.merge(config, map_to_keyword(overrides))
  end

  defp merge_map(config, overrides) when is_list(overrides), do: Keyword.merge(config, overrides)
  defp merge_map(config, _overrides), do: config

  defp map_to_keyword(map) do
    Enum.map(map, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize(config) do
    config
    |> Keyword.update(:on_error, :fail, &normalize_key/1)
    |> Keyword.update(:provider, None, &normalize_provider/1)
  end

  defp normalize_provider(provider) when is_atom(provider), do: provider
  defp normalize_provider("good_analytics"), do: GoodAnalytics
  defp normalize_provider("module"), do: ModuleAdapter
  defp normalize_provider("webhook"), do: Webhook
  defp normalize_provider("none"), do: None
  defp normalize_provider(provider), do: provider

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key),
    do: key |> String.downcase() |> DripDrop.Helpers.atom_or_string()
end
