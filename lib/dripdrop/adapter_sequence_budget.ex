defmodule DripDrop.AdapterSequenceBudget do
  @moduledoc """
  Per-adapter, per-sequence outbound send-share budget.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias DripDrop.{ChannelAdapter, SequenceVersion}

  @primary_key {:id, :binary_id, autogenerate: false, read_after_writes: true}
  @foreign_key_type :binary_id
  @schema_prefix "dripdrop"

  schema "adapter_sequence_budgets" do
    field(:tenant_key, :string)
    field(:weight, :integer, default: 1)
    field(:max_share_pct, :integer, default: 100)
    field(:daily_volume_target, :integer)

    belongs_to(:adapter, ChannelAdapter)
    belongs_to(:sequence_version, SequenceVersion)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for adapter sequence budget records.
  """
  @spec changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(budget, attrs) do
    budget
    |> cast(attrs, [
      :adapter_id,
      :sequence_version_id,
      :tenant_key,
      :weight,
      :max_share_pct,
      :daily_volume_target
    ])
    |> validate_required([:adapter_id, :sequence_version_id])
    |> validate_number(:weight, greater_than: 0)
    |> validate_number(:max_share_pct, greater_than_or_equal_to: 1, less_than_or_equal_to: 100)
    |> validate_number(:daily_volume_target, greater_than: 0)
    |> unique_constraint(:adapter_id, name: :adapter_sequence_budgets_adapter_sequence_idx)
    |> foreign_key_constraint(:adapter_id)
    |> foreign_key_constraint(:sequence_version_id)
  end
end
