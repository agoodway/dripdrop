defmodule DripDrop.Channels.Payload do
  @moduledoc """
  Extracts rendered provider payload data from steps.
  """

  alias DripDrop.Helpers

  @doc """
  Returns an atom-keyed payload map from supported step shapes.
  """
  @spec get(map()) :: map()
  def get(%{config: %{"payload" => payload}}) when is_map(payload),
    do: Helpers.atomize_existing_keys_strict(payload)

  def get(%{config: %{payload: payload}}) when is_map(payload),
    do: Helpers.atomize_existing_keys_strict(payload)

  def get(%{"config" => %{"payload" => payload}}) when is_map(payload),
    do: Helpers.atomize_existing_keys_strict(payload)

  def get(%{template_content: payload}) when is_map(payload),
    do: Helpers.atomize_existing_keys_strict(payload)

  def get(%{"template_content" => payload}) when is_map(payload),
    do: Helpers.atomize_existing_keys_strict(payload)

  def get(_step), do: %{}
end
