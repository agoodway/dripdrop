defmodule DripDrop.StepTransition do
  @moduledoc """
  Explicit edge between steps, or from sequence entry / to completion.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias DripDrop.{Condition, SequenceVersion, Step}

  @primary_key {:id, :binary_id, autogenerate: false, read_after_writes: true}
  @foreign_key_type :binary_id
  @schema_prefix "dripdrop"
  @condition_modes ~w(always all any)

  schema "step_transitions" do
    field(:tenant_key, :string)
    field(:condition_mode, :string, default: "always")
    field(:priority, :integer, default: 0)
    field(:config, :map, default: %{})

    belongs_to(:sequence_version, SequenceVersion)
    belongs_to(:from_step, Step)
    belongs_to(:to_step, Step)
    has_many(:conditions, Condition, foreign_key: :transition_id)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for ordered transitions between steps.
  """
  @spec changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(transition, attrs) do
    transition
    |> cast(attrs, [
      :sequence_version_id,
      :tenant_key,
      :from_step_id,
      :to_step_id,
      :condition_mode,
      :priority,
      :config
    ])
    |> validate_required([:sequence_version_id, :condition_mode, :priority])
    |> validate_inclusion(:condition_mode, @condition_modes)
    |> foreign_key_constraint(:from_step_id)
    |> foreign_key_constraint(:to_step_id)
    |> foreign_key_constraint(:sequence_version_id)
  end
end
