defmodule DripDrop.SequenceVersion do
  @moduledoc """
  Immutable authoring version for a sequence.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias DripDrop.{Clock, Sequence, Step, StepTransition}

  @primary_key {:id, :binary_id, autogenerate: false, read_after_writes: true}
  @foreign_key_type :binary_id
  @schema_prefix "dripdrop"
  @states ~w(draft active archived)

  @type t :: %__MODULE__{}

  schema "sequence_versions" do
    field(:tenant_key, :string)
    field(:version, :integer)
    field(:name, :string)
    field(:state, :string, default: "draft")

    field(:mode, Ecto.Enum,
      values: [lifecycle: "lifecycle", outbound: "outbound"],
      default: :lifecycle
    )

    field(:config, :map, default: %{})
    field(:published_at, :utc_datetime)

    belongs_to(:sequence, Sequence)
    has_many(:steps, Step)
    has_many(:transitions, StepTransition)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for sequence version records.
  """
  @spec changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(version, attrs) do
    version
    |> cast(attrs, [
      :sequence_id,
      :tenant_key,
      :version,
      :name,
      :state,
      :mode,
      :config,
      :published_at
    ])
    |> validate_required([:sequence_id, :version])
    |> validate_number(:version, greater_than: 0)
    |> validate_inclusion(:state, @states)
    |> validate_mode_immutable_after_publish()
    |> unique_constraint(:version, name: :sequence_versions_sequence_version_idx)
    |> unique_constraint(:state, name: :sequence_versions_one_active_idx)
    |> foreign_key_constraint(:sequence_id)
  end

  @doc """
  Marks a sequence version active and stamps its publish time.
  """
  @spec activate_changeset(Ecto.Schema.t()) :: Ecto.Changeset.t()
  def activate_changeset(version) do
    version
    |> change(state: "active", published_at: Clock.now())
    |> unique_constraint(:state, name: :sequence_versions_one_active_idx)
  end

  @doc """
  Marks a sequence version archived.
  """
  @spec archive_changeset(Ecto.Schema.t()) :: Ecto.Changeset.t()
  def archive_changeset(version), do: change(version, state: "archived")

  defp validate_mode_immutable_after_publish(changeset) do
    if changeset.data.__meta__.state == :loaded and get_field(changeset, :state) == "active" and
         changed?(changeset, :mode) do
      add_error(changeset, :mode, "mode_immutable_after_publish")
    else
      changeset
    end
  end
end
