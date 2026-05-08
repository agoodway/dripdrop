defmodule DripDrop.StepExecution do
  @moduledoc """
  A scheduled or completed attempt to run one step for one enrollment.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias DripDrop.{Enrollment, Step}

  @primary_key {:id, :binary_id, autogenerate: false, read_after_writes: true}
  @foreign_key_type :binary_id
  @schema_prefix "dripdrop"
  @states ~w(scheduled claiming sending sent failed skipped cancelled)

  schema "step_executions" do
    field(:tenant_key, :string)
    field(:state, :string, default: "scheduled")
    field(:scheduled_for, :utc_datetime)
    field(:claimed_at, :utc_datetime)
    field(:executed_at, :utc_datetime)
    field(:failed_at, :utc_datetime)
    field(:retry_count, :integer, default: 0)
    field(:attempt_window, :integer, default: 0)
    field(:idempotency_key, :string)
    field(:scheduler_job_id, :string)
    field(:scheduler_backend, :string)
    field(:channel, :string)
    field(:recipient, :string)
    field(:payload, :map)
    field(:response, :map)
    field(:provider_message_id, :string)
    field(:out_message_id, :string)
    field(:error_message, :string)
    field(:metadata, :map, default: %{})

    belongs_to(:enrollment, Enrollment)
    belongs_to(:step, Step)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for dispatch step execution rows.
  """
  @spec changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(execution, attrs) do
    execution
    |> cast(attrs, [
      :enrollment_id,
      :step_id,
      :tenant_key,
      :state,
      :scheduled_for,
      :claimed_at,
      :executed_at,
      :failed_at,
      :retry_count,
      :attempt_window,
      :idempotency_key,
      :scheduler_job_id,
      :scheduler_backend,
      :channel,
      :recipient,
      :payload,
      :response,
      :provider_message_id,
      :out_message_id,
      :error_message,
      :metadata
    ])
    |> validate_required([
      :enrollment_id,
      :step_id,
      :state,
      :scheduled_for,
      :idempotency_key,
      :channel
    ])
    |> validate_inclusion(:state, @states)
    |> unique_constraint(:idempotency_key, name: :step_executions_idempotency_key_idx)
    |> foreign_key_constraint(:enrollment_id)
    |> foreign_key_constraint(:step_id)
  end
end
