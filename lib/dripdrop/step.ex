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
      :config,
      :active
    ])
    |> cast_embed(:timing, required: true)
    |> validate_required([:sequence_version_id, :name, :key, :channel])
    |> validate_inclusion(:channel, @channels)
    |> validate_inclusion(:template_type, @template_types)
    |> unique_constraint(:key, name: :steps_version_key_idx)
    |> unique_constraint(:position, name: :steps_version_position_idx)
    |> foreign_key_constraint(:channel_adapter_id)
    |> foreign_key_constraint(:sequence_version_id)
  end
end
