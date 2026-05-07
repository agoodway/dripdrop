defmodule DripDrop.Config do
  @moduledoc """
  Small configuration helpers used across DripDrop.
  """

  @doc """
  Fetches a required DripDrop application environment value.
  """
  @spec fetch!(atom()) :: term()
  def fetch!(key), do: Application.fetch_env!(:dripdrop, key)

  @doc """
  Reads an optional DripDrop application environment value.
  """
  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil), do: Application.get_env(:dripdrop, key, default)

  @doc """
  Converts a binary to an existing atom and returns `nil` when it is unknown.
  """
  @spec to_existing_atom(atom() | String.t()) :: atom() | nil
  def to_existing_atom(value) when is_atom(value), do: value

  def to_existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end
end
