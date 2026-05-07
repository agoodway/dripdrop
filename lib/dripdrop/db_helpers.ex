defmodule DripDrop.DBHelpers do
  @moduledoc """
  Small helpers for crossing raw SQL and Ecto schema boundaries.

  `Repo.query/3` uses Postgrex types directly, while Ecto schemas expose UUIDs
  as canonical strings. These helpers keep that conversion in one place.
  """

  alias Ecto.UUID

  @doc """
  Converts an Ecto UUID string into the 16-byte form expected by `$uuid` params.

  Values that are already dumped, invalid, or non-binary are returned unchanged
  so callers can safely pass through database-driver values.
  """
  @spec dump_uuid(term()) :: term()
  def dump_uuid(<<_::128>> = uuid), do: uuid

  def dump_uuid(uuid) when is_binary(uuid) do
    case UUID.dump(uuid) do
      {:ok, uuid} -> uuid
      :error -> uuid
    end
  end

  def dump_uuid(uuid), do: uuid

  @doc """
  Converts a raw 16-byte UUID returned by Postgrex into an Ecto UUID string.
  """
  @spec load_uuid(term()) :: term()
  def load_uuid(<<_::128>> = uuid) do
    case UUID.load(uuid) do
      {:ok, uuid} -> uuid
      :error -> uuid
    end
  end

  def load_uuid(uuid), do: uuid
end
