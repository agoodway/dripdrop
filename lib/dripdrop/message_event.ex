defmodule DripDrop.MessageEvent do
  @moduledoc """
  A normalized provider event emitted after delivery or inbound webhook ingest.

  Message events are used for audit trails, suppression handling, reply
  detection, and sender-level sending rules such as daily caps.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias DripDrop.StepExecution

  @primary_key {:id, :binary_id, autogenerate: false, read_after_writes: true}
  @foreign_key_type :binary_id
  @schema_prefix "dripdrop"
  @event_types ~w(delivered bounced complained opened clicked replied unsubscribed sent failed skipped deferred suppressed)

  schema "message_events" do
    field(:tenant_key, :string)
    field(:channel, :string)
    field(:provider, :string)
    field(:provider_message_id, :string)
    field(:provider_event_id, :string)
    field(:event_type, :string)
    field(:event_data, :map, default: %{})
    field(:occurred_at, :utc_datetime)

    belongs_to(:step_execution, StepExecution)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Builds a changeset for normalized provider message events.
  """
  @spec changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :step_execution_id,
      :tenant_key,
      :channel,
      :provider,
      :provider_message_id,
      :provider_event_id,
      :event_type,
      :event_data,
      :occurred_at
    ])
    |> validate_required([:channel, :provider, :event_type])
    |> validate_inclusion(:event_type, @event_types)
    |> foreign_key_constraint(:step_execution_id)
    |> unique_constraint(:provider_event_id, name: :message_events_provider_event_idx)
  end
end
