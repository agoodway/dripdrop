defmodule DripDrop.Condition do
  @moduledoc """
  Runtime condition attached to a step or branch transition.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias DripDrop.Conditions.Predicate
  alias DripDrop.{HttpHook, Step, StepTransition}

  @primary_key {:id, :binary_id, autogenerate: false, read_after_writes: true}
  @foreign_key_type :binary_id
  @schema_prefix "dripdrop"
  @condition_types ~w(hook enrollment_data event predicate time_window)
  @operators ~w(== != > < >= <= in contains)

  schema "conditions" do
    field(:tenant_key, :string)
    field(:condition_type, :string)
    field(:operator, :string, default: "==")
    field(:hook_function, :string)
    field(:field_path, :string)
    field(:expected_value, :string)
    field(:config, :map, default: %{})

    belongs_to(:step, Step)
    belongs_to(:transition, StepTransition)
    belongs_to(:http_hook, HttpHook)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for branch condition rows.
  """
  @spec changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(condition, attrs) do
    condition
    |> cast(attrs, [
      :tenant_key,
      :step_id,
      :transition_id,
      :condition_type,
      :operator,
      :hook_function,
      :http_hook_id,
      :field_path,
      :expected_value,
      :config
    ])
    |> validate_required([:condition_type, :operator])
    |> validate_inclusion(:condition_type, @condition_types)
    |> validate_inclusion(:operator, @operators)
    |> validate_attachment()
    |> validate_by_type()
    |> validate_predicate()
    |> foreign_key_constraint(:http_hook_id)
    |> foreign_key_constraint(:step_id)
    |> foreign_key_constraint(:transition_id)
    |> check_constraint(:step_id,
      name: :conditions_step_or_transition_xor,
      message: "exactly one of step_id / transition_id must be set"
    )
  end

  defp validate_attachment(changeset) do
    step_id = get_field(changeset, :step_id)
    transition_id = get_field(changeset, :transition_id)

    cond do
      is_nil(step_id) and is_nil(transition_id) ->
        add_error(changeset, :step_id, "or transition_id is required")

      not is_nil(step_id) and not is_nil(transition_id) ->
        add_error(changeset, :step_id, "only one of step_id / transition_id may be set")

      true ->
        changeset
    end
  end

  defp validate_by_type(changeset) do
    case get_field(changeset, :condition_type) do
      "hook" -> validate_hook_condition(changeset)
      "enrollment_data" -> validate_required(changeset, [:field_path, :expected_value])
      "event" -> validate_required(changeset, [:expected_value])
      "predicate" -> validate_predicate_condition(changeset)
      "time_window" -> changeset
      _other -> changeset
    end
  end

  defp validate_predicate_condition(changeset) do
    changeset =
      validate_change(changeset, :config, fn :config, config ->
        if predicate(config), do: [], else: [config: "predicate is required"]
      end)

    validate_required(changeset, [:config])
  end

  defp validate_predicate(changeset) do
    predicate =
      changeset
      |> get_field(:config, %{})
      |> predicate()

    case Predicate.validate(predicate) do
      :ok ->
        changeset

      {:error, reason} ->
        add_error(changeset, :config, "predicate is invalid: #{inspect(reason)}")
    end
  end

  defp validate_hook_condition(changeset) do
    if get_field(changeset, :hook_function) || get_field(changeset, :http_hook_id) do
      changeset
    else
      add_error(changeset, :hook_function, "or http_hook_id is required")
    end
  end

  defp predicate(config) when is_map(config),
    do: Map.get(config, "predicate") || Map.get(config, :predicate)

  defp predicate(_config), do: nil
end
