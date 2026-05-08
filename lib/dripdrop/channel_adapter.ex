defmodule DripDrop.ChannelAdapter do
  @moduledoc """
  Configures one provider implementation for a DripDrop channel.

  Credentials are encrypted at rest and provider validation is delegated to the
  registered channel module so built-in and host-registered adapters follow the
  same contract.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias DripDrop.Channels
  alias DripDrop.Encrypted

  @primary_key {:id, :binary_id, autogenerate: false, read_after_writes: true}
  @foreign_key_type :binary_id
  @schema_prefix "dripdrop"

  @derive {Inspect, except: [:credentials]}
  schema "channel_adapters" do
    field(:tenant_key, :string)
    field(:name, :string)
    field(:channel, :string)
    field(:provider, :string)
    field(:credentials, Encrypted.Map)
    field(:config, :map, default: %{})
    field(:is_default, :boolean, default: false)
    field(:active, :boolean, default: true)

    field(:health_state, Ecto.Enum,
      values: [active: "active", resting: "resting", probing: "probing", ramping: "ramping"]
    )

    field(:health_score, :decimal)
    field(:resting_until, :utc_datetime)
    field(:last_send_at, :utc_datetime)
    field(:daily_cap, :integer)
    field(:ramp_started_at, :utc_datetime)
    field(:ramp_increment, :integer)
    field(:ramp_floor, :integer)
    field(:min_gap_seconds, :integer)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for creating or updating a channel adapter.
  """
  @spec changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(adapter, attrs) do
    adapter
    |> cast(attrs, [
      :tenant_key,
      :name,
      :channel,
      :provider,
      :credentials,
      :config,
      :is_default,
      :active,
      :health_state,
      :health_score,
      :resting_until,
      :last_send_at,
      :daily_cap,
      :ramp_started_at,
      :ramp_increment,
      :ramp_floor,
      :min_gap_seconds
    ])
    |> validate_required([:name, :channel, :provider])
    |> validate_number(:health_score, greater_than_or_equal_to: 0, less_than_or_equal_to: 1)
    |> validate_number(:daily_cap, greater_than: 0)
    |> validate_number(:ramp_increment, greater_than: 0)
    |> validate_number(:ramp_floor, greater_than_or_equal_to: 0)
    |> validate_number(:min_gap_seconds, greater_than_or_equal_to: 0)
    |> validate_channel()
    |> validate_provider()
    |> validate_credentials()
    |> unique_constraint(:is_default,
      name: :channel_adapters_tenant_default_idx,
      message: "another tenant adapter is already the default for this channel"
    )
    |> unique_constraint(:is_default,
      name: :channel_adapters_global_default_idx,
      message: "another global adapter is already the default for this channel"
    )
  end

  defp validate_channel(changeset) do
    validate_change(changeset, :channel, fn :channel, channel ->
      if channel in Enum.map(Channels.channels(), &to_string/1) do
        []
      else
        [channel: "is not a registered channel"]
      end
    end)
  end

  defp validate_provider(changeset) do
    channel = get_field(changeset, :channel)
    provider = get_field(changeset, :provider)

    case Channels.provider_module(channel, provider) do
      {:ok, _module} ->
        changeset

      {:error, _reason} ->
        add_error(changeset, :provider, "is not registered for channel")
    end
  end

  defp validate_credentials(changeset) do
    credentials = get_field(changeset, :credentials) || %{}

    module =
      case Channels.provider_module(
             get_field(changeset, :channel),
             get_field(changeset, :provider)
           ) do
        {:ok, module} -> module
        _error -> nil
      end

    case module && module.validate_credentials(credentials) do
      :ok -> changeset
      {:error, errors} -> Enum.reduce(errors, changeset, &add_credential_error/2)
      nil -> changeset
    end
  end

  defp add_credential_error({key, message}, changeset) do
    add_error(changeset, :credentials, "#{key} #{message}")
  end
end
