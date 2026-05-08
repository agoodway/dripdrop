defmodule DripDrop.AdapterPoolMember do
  @moduledoc """
  Membership row connecting an adapter pool to a channel adapter.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias DripDrop.{AdapterPool, ChannelAdapter, Repo}

  @primary_key {:id, :binary_id, autogenerate: false, read_after_writes: true}
  @foreign_key_type :binary_id
  @schema_prefix "dripdrop"
  @esp_only_providers ~w(mailgun sendgrid postmark mailersend ses)

  @type t :: %__MODULE__{}

  schema "adapter_pool_members" do
    field(:tenant_key, :string)
    field(:class, Ecto.Enum, values: [mailbox: "mailbox", esp_api: "esp_api"], default: :mailbox)
    field(:weight, :integer, default: 1)
    field(:active, :boolean, default: true)

    belongs_to(:pool, AdapterPool)
    belongs_to(:adapter, ChannelAdapter)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for adapter pool member records.
  """
  @spec changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(member, attrs) do
    member
    |> cast(attrs, [:pool_id, :adapter_id, :tenant_key, :class, :weight, :active])
    |> validate_required([:pool_id, :adapter_id])
    |> validate_number(:weight, greater_than: 0)
    |> validate_mailbox_class()
    |> unique_constraint(:adapter_id, name: :adapter_pool_members_pool_adapter_idx)
    |> foreign_key_constraint(:pool_id)
    |> foreign_key_constraint(:adapter_id)
  end

  defp validate_mailbox_class(changeset) do
    if get_field(changeset, :class) == :mailbox do
      case Repo.get(ChannelAdapter, get_field(changeset, :adapter_id)) do
        %ChannelAdapter{provider: provider} when provider in @esp_only_providers ->
          add_error(changeset, :class, "class_mismatch")

        _adapter ->
          changeset
      end
    else
      changeset
    end
  end
end
