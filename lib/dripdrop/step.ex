defmodule DripDrop.Step do
  @moduledoc """
  A sequence step with channel, timing, and template configuration.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias DripDrop.{ChannelAdapter, Condition, SequenceVersion, Timing}

  @primary_key {:id, :binary_id, autogenerate: false, read_after_writes: true}
  @foreign_key_type :binary_id
  @schema_prefix "dripdrop"
  @channels ~w(email sms webhook pubsub slack telegram whatsapp)
  @template_types ~w(inline module external)

  schema "steps" do
    field(:tenant_key, :string)
    field(:name, :string)
    field(:key, :string)
    field(:position, :integer)
    field(:channel, :string)
    embeds_one(:timing, Timing, on_replace: :update)
    field(:template_type, :string, default: "inline")
    field(:template_content, :map, default: %{})
    field(:template_module, :string)
    field(:template_function, :string)
    field(:config, :map, default: %{})
    field(:active, :boolean, default: true)

    belongs_to(:sequence_version, SequenceVersion)
    belongs_to(:channel_adapter, ChannelAdapter)
    belongs_to(:adapter_override, ChannelAdapter)
    has_many(:conditions, Condition)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for sequence steps and embedded timing.
  """
  @spec changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(step, attrs) do
    step
    |> cast(attrs, [
      :sequence_version_id,
      :tenant_key,
      :name,
      :key,
      :position,
      :channel,
      :template_type,
      :template_content,
      :template_module,
      :template_function,
      :channel_adapter_id,
      :adapter_override_id,
      :config,
      :active
    ])
    |> cast_embed(:timing, required: true)
    |> validate_required([:sequence_version_id, :name, :key, :channel])
    |> validate_inclusion(:channel, @channels)
    |> validate_inclusion(:template_type, @template_types)
    |> validate_adapter_override_conflict()
    |> unique_constraint(:key, name: :steps_version_key_idx)
    |> unique_constraint(:position, name: :steps_version_position_idx)
    |> foreign_key_constraint(:channel_adapter_id)
    |> foreign_key_constraint(:adapter_override_id)
    |> foreign_key_constraint(:sequence_version_id)
  end

  defp validate_adapter_override_conflict(changeset) do
    if get_field(changeset, :channel_adapter_id) && get_field(changeset, :adapter_override_id) do
      add_error(changeset, :adapter_override_id, "cannot be set with channel_adapter_id")
    else
      changeset
    end
  end
end
