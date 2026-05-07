defmodule DripDrop.Event do
  @moduledoc """
  Host or subscriber event used to trigger event-timed sequence steps.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias DripDrop.Enrollment

  @primary_key {:id, :binary_id, autogenerate: false, read_after_writes: true}
  @foreign_key_type :binary_id
  @schema_prefix "dripdrop"

  schema "events" do
    field(:tenant_key, :string)
    field(:subscriber_type, :string)
    field(:subscriber_id, :string)
    field(:event_type, :string, default: "custom")
    field(:event_key, :string)
    field(:event_data, :map, default: %{})
    field(:occurred_at, :utc_datetime)

    belongs_to(:enrollment, Enrollment)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Builds a changeset for tracked subscriber events.
  """
  @spec changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :enrollment_id,
      :tenant_key,
      :subscriber_type,
      :subscriber_id,
      :event_type,
      :event_key,
      :event_data,
      :occurred_at
    ])
    |> validate_required([:event_key])
    |> validate_identity()
    |> foreign_key_constraint(:enrollment_id)
  end

  defp validate_identity(changeset) do
    has_enrollment? = get_field(changeset, :enrollment_id)

    has_subscriber? =
      get_field(changeset, :subscriber_type) && get_field(changeset, :subscriber_id)

    if has_enrollment? || has_subscriber? do
      changeset
    else
      add_error(changeset, :enrollment_id, "or subscriber_type/subscriber_id is required")
    end
  end
end
