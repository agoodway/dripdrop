defmodule DripDrop.ShortLink do
  @moduledoc """
  Persisted audit row for a URL rewritten through the short-link pipeline.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false, read_after_writes: true}
  @foreign_key_type :binary_id
  @schema_prefix "dripdrop"

  schema "short_links" do
    field(:step_execution_id, :binary_id)
    field(:tenant_key, :string)
    field(:provider, :string)
    field(:original_url, :string)
    field(:destination_url, :string)
    field(:short_url, :string)
    field(:external_id, :string)
    field(:idempotency_key, :string)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for persisted short-link audit rows.
  """
  @spec changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(short_link, attrs) do
    short_link
    |> cast(attrs, [
      :step_execution_id,
      :tenant_key,
      :provider,
      :original_url,
      :destination_url,
      :short_url,
      :external_id,
      :idempotency_key,
      :metadata
    ])
    |> validate_required([:provider, :original_url, :destination_url, :idempotency_key])
    |> unique_constraint(:idempotency_key, name: :short_links_idempotency_key_idx)
    |> foreign_key_constraint(:step_execution_id)
  end
end
