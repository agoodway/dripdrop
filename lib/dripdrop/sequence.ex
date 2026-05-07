defmodule DripDrop.Sequence do
  @moduledoc """
  Sequence definition shared by one or more immutable versions.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias DripDrop.SequenceVersion

  @primary_key {:id, :binary_id, autogenerate: false, read_after_writes: true}
  @foreign_key_type :binary_id
  @schema_prefix "dripdrop"

  schema "sequences" do
    field(:tenant_key, :string)
    field(:name, :string)
    field(:key, :string)
    field(:description, :string)
    field(:hook_module, :string)
    field(:active, :boolean, default: true)
    field(:metadata, :map, default: %{})

    has_many(:versions, SequenceVersion)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for sequence authoring records.
  """
  @spec changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(sequence, attrs) do
    sequence
    |> cast(attrs, [:tenant_key, :name, :key, :description, :hook_module, :active, :metadata])
    |> validate_required([:name, :key])
    |> update_change(:key, &normalize_key/1)
    |> validate_format(:key, ~r/^[a-z0-9][a-z0-9_-]*$/)
    |> unique_constraint(:key, name: :sequences_key_global_idx)
    |> unique_constraint(:key, name: :sequences_tenant_key_idx)
  end

  defp normalize_key(nil), do: nil

  defp normalize_key(key) when is_binary(key) do
    key
    |> String.trim()
    |> String.downcase()
  end
end
