defmodule DripDrop.Enrollment do
  @moduledoc """
  A subscriber's lifecycle through a sequence.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias DripDrop.{Clock, Sequence, SequenceVersion, Step, StepExecution}

  @primary_key {:id, :binary_id, autogenerate: false, read_after_writes: true}
  @foreign_key_type :binary_id
  @schema_prefix "dripdrop"
  @states ~w(active paused completed cancelled)
  @transitions %{
    "active" => ~w(paused completed cancelled),
    "paused" => ~w(active cancelled),
    "completed" => [],
    "cancelled" => []
  }

  schema "enrollments" do
    field(:tenant_key, :string)
    field(:subscriber_type, :string)
    field(:subscriber_id, :string)
    field(:state, :string, default: "active")
    field(:started_at, :utc_datetime)
    field(:completed_at, :utc_datetime)
    field(:cancelled_at, :utc_datetime)
    field(:data, :map, default: %{})
    field(:metadata, :map, default: %{})

    belongs_to(:sequence, Sequence)
    belongs_to(:sequence_version, SequenceVersion)
    belongs_to(:current_step, Step)
    has_many(:step_executions, StepExecution)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for an enrollment lifecycle row.
  """
  @spec changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(enrollment, attrs) do
    enrollment
    |> cast(attrs, [
      :sequence_id,
      :sequence_version_id,
      :tenant_key,
      :subscriber_type,
      :subscriber_id,
      :state,
      :current_step_id,
      :started_at,
      :completed_at,
      :cancelled_at,
      :data,
      :metadata
    ])
    |> validate_required([:sequence_id, :sequence_version_id, :subscriber_type, :subscriber_id])
    |> validate_inclusion(:state, @states)
    |> unique_constraint(:subscriber_id,
      name: :enrollments_active_subscriber_tenant_idx,
      message: "already enrolled (active or paused) in this sequence"
    )
    |> unique_constraint(:subscriber_id,
      name: :enrollments_active_subscriber_global_idx,
      message: "already enrolled (active or paused) in this sequence"
    )
    |> foreign_key_constraint(:sequence_id)
    |> foreign_key_constraint(:sequence_version_id)
    |> foreign_key_constraint(:current_step_id)
  end

  @doc """
  Builds a state-transition changeset when the transition is allowed.
  """
  @spec transition_changeset(Ecto.Schema.t(), binary()) :: Ecto.Changeset.t()
  def transition_changeset(%__MODULE__{} = enrollment, next_state) when next_state in @states do
    if allowed_transition?(enrollment.state, next_state) do
      enrollment
      |> change(state: next_state)
      |> put_terminal_timestamp(next_state)
    else
      enrollment
      |> change()
      |> add_error(:state, "invalid transition")
    end
  end

  @spec allowed_transition?(binary(), binary()) :: boolean()
  @doc """
  Returns true when an enrollment can move from `state` to `next_state`.
  """
  def allowed_transition?(state, next_state), do: next_state in Map.get(@transitions, state, [])

  defp put_terminal_timestamp(changeset, "completed") do
    put_change(changeset, :completed_at, Clock.now())
  end

  defp put_terminal_timestamp(changeset, "cancelled") do
    put_change(changeset, :cancelled_at, Clock.now())
  end

  defp put_terminal_timestamp(changeset, _state), do: changeset
end
