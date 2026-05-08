defmodule DripDrop.AdapterPool do
  @moduledoc """
  Tenant-scoped sender pool used by outbound sequence versions.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias DripDrop.AdapterPoolMember

  @primary_key {:id, :binary_id, autogenerate: false, read_after_writes: true}
  @foreign_key_type :binary_id
  @schema_prefix "dripdrop"

  @type t :: %__MODULE__{}

  schema "adapter_pools" do
    field(:tenant_key, :string)
    field(:name, :string)

    field(:on_pin_unavailable, Ecto.Enum,
      values: [pause: "pause", reassign: "reassign"],
      default: :reassign
    )

    field(:metadata, :map, default: %{})

    has_many(:members, AdapterPoolMember, foreign_key: :pool_id)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for adapter pool records.
  """
  @spec changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(pool, attrs) do
    pool
    |> cast(attrs, [:tenant_key, :name, :on_pin_unavailable, :metadata])
    |> validate_required([:name])
    |> unique_constraint(:name,
      name: :adapter_pools_tenant_name_idx,
      message: "already exists for this tenant"
    )
    |> unique_constraint(:name,
      name: :adapter_pools_global_name_idx,
      message: "already exists globally"
    )
  end
end
