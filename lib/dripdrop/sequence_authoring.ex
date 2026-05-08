defmodule DripDrop.SequenceAuthoring do
  @moduledoc """
  Public authoring API for sequences, versions, steps, transitions, and conditions.
  """

  import Ecto.Query

  alias Ecto.Multi

  alias DripDrop.{
    AdapterPool,
    AdapterPoolMember,
    Clock,
    Condition,
    Helpers,
    Repo,
    Sequence,
    SequenceVersion,
    Step,
    StepTransition,
    Templates,
    Timing
  }

  alias DripDrop.{ChannelAdapter, HttpHook}
  alias DripDrop.Conditions.Predicate

  alias Crontab.CronExpression.Parser

  @spec create_sequence(map()) :: {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Creates a sequence definition.
  """
  def create_sequence(attrs) when is_map(attrs) do
    %Sequence{}
    |> Sequence.changeset(attrs)
    |> Repo.insert()
  end

  @spec create_sequence_version(Ecto.UUID.t(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Creates an immutable authoring version for a sequence.
  """
  def create_sequence_version(sequence_id, attrs) when is_map(attrs) do
    sequence = Repo.repo!().get!(Sequence, sequence_id)

    attrs =
      attrs
      |> Map.put(:sequence_id, sequence_id)
      |> Map.put(:tenant_key, sequence.tenant_key)

    %SequenceVersion{}
    |> SequenceVersion.changeset(attrs)
    |> Repo.insert()
  end

  @spec activate_sequence_version(Ecto.UUID.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, term()}
  @doc """
  Activates a sequence version and archives any previously active version.
  """
  def activate_sequence_version(version_id) do
    repo = Repo.repo!()
    version = repo.get!(SequenceVersion, version_id)

    Multi.new()
    |> Multi.update_all(:archive_previous, active_versions_query(version),
      set: [state: "archived", updated_at: Clock.now()]
    )
    |> Multi.update(:activate, SequenceVersion.activate_changeset(version))
    |> Repo.transaction()
    |> case do
      {:ok, %{activate: activated}} -> {:ok, activated}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @spec create_step(Ecto.UUID.t(), map()) :: {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Creates a step in a sequence version.
  """
  def create_step(version_id, attrs) when is_map(attrs) do
    version = Repo.repo!().get!(SequenceVersion, version_id)

    attrs =
      attrs
      |> Map.put(:sequence_version_id, version_id)
      |> Map.put(:tenant_key, version.tenant_key)

    %Step{}
    |> Step.changeset(attrs)
    |> Repo.insert()
  end

  @spec create_step_transition(Ecto.UUID.t(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Creates a transition between sequence steps.
  """
  def create_step_transition(version_id, attrs) when is_map(attrs) do
    version = Repo.repo!().get!(SequenceVersion, version_id)

    attrs =
      attrs
      |> Map.put(:sequence_version_id, version_id)
      |> Map.put(:tenant_key, version.tenant_key)

    %StepTransition{}
    |> StepTransition.changeset(attrs)
    |> Repo.insert()
  end

  @spec create_condition(Ecto.UUID.t(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Creates a condition attached to a step or transition.
  """
  def create_condition(owner_id, attrs) when is_map(attrs) do
    repo = Repo.repo!()
    attrs = attach_owner(owner_id, attrs)
    parent_tenant_key = condition_parent_tenant_key!(repo, attrs)

    attrs = Map.put(attrs, :tenant_key, parent_tenant_key)

    %Condition{}
    |> Condition.changeset(attrs)
    |> Repo.insert()
  end

  @spec validate_sequence_version(Ecto.UUID.t()) :: {:ok, Ecto.Schema.t()} | {:error, list()}
  @doc """
  Validates that a sequence version is structurally dispatchable.
  """
  def validate_sequence_version(version_id) do
    repo = Repo.repo!()

    version =
      SequenceVersion
      |> repo.get!(version_id)
      |> repo.preload([:sequence, steps: [:conditions], transitions: [:conditions]])

    errors =
      []
      |> maybe_add_entry_error(version)
      |> maybe_add_outbound_errors(version)
      |> maybe_add_adapter_errors(version)
      |> maybe_add_condition_errors(version)
      |> maybe_add_hook_reference_errors(version)
      |> maybe_add_cron_errors(version)
      |> maybe_add_template_errors(version)

    case errors do
      [] -> {:ok, version}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  defp active_versions_query(%SequenceVersion{sequence_id: sequence_id, id: id}) do
    from(version in SequenceVersion,
      where: version.sequence_id == ^sequence_id,
      where: version.id != ^id,
      where: version.state == "active"
    )
  end

  defp attach_owner(owner_id, attrs) do
    owner_key =
      if Map.has_key?(attrs, :transition_id) or Map.has_key?(attrs, "transition_id") do
        :transition_id
      else
        :step_id
      end

    Map.put(attrs, owner_key, owner_id)
  end

  defp condition_parent_tenant_key!(repo, %{transition_id: transition_id})
       when not is_nil(transition_id),
       do: repo.get!(StepTransition, transition_id).tenant_key

  defp condition_parent_tenant_key!(repo, %{"transition_id" => transition_id})
       when not is_nil(transition_id),
       do: repo.get!(StepTransition, transition_id).tenant_key

  defp condition_parent_tenant_key!(repo, %{step_id: step_id}) when not is_nil(step_id),
    do: repo.get!(Step, step_id).tenant_key

  defp condition_parent_tenant_key!(repo, %{"step_id" => step_id}) when not is_nil(step_id),
    do: repo.get!(Step, step_id).tenant_key

  defp maybe_add_entry_error(errors, %{steps: steps, transitions: transitions}) do
    has_entry_transition? = Enum.any?(transitions, &is_nil(&1.from_step_id))
    has_position_entry? = Enum.any?(steps, &is_integer(&1.position))

    if has_entry_transition? or has_position_entry? do
      errors
    else
      [{:no_entry_path, "no entry transition or positioned step exists"} | errors]
    end
  end

  defp maybe_add_cron_errors(errors, %{steps: steps}) do
    Enum.reduce(steps, errors, fn
      %Step{timing: %{type: "cron", cron_expression: expr}, key: key}, acc ->
        case Timing.parse_human_friendly(expr) do
          {:ok, _parsed} -> acc
          {:error, _reason} -> validate_raw_cron(acc, key, expr)
        end

      _step, acc ->
        acc
    end)
  end

  defp maybe_add_adapter_errors(errors, %{steps: steps}) do
    adapter_ids =
      steps
      |> Enum.flat_map(&step_adapter_ids/1)
      |> Enum.uniq()

    adapters =
      ChannelAdapter
      |> where([adapter], adapter.id in ^adapter_ids)
      |> select([adapter], {adapter.id, adapter.channel})
      |> Repo.all()
      |> Map.new()

    Enum.reduce(steps, errors, &add_adapter_errors_for_step(&1, &2, adapters))
  end

  defp maybe_add_outbound_errors(errors, %SequenceVersion{mode: :outbound} = version) do
    pool_id = pool_id(version.config || %{})

    errors
    |> maybe_add_missing_pool_error(pool_id)
    |> maybe_add_pool_reference_error(version, pool_id)
    |> maybe_add_override_errors(version)
  end

  defp maybe_add_outbound_errors(errors, _version), do: errors

  defp maybe_add_missing_pool_error(errors, nil), do: [{:outbound_requires_pool, nil} | errors]
  defp maybe_add_missing_pool_error(errors, _pool_id), do: errors

  defp maybe_add_pool_reference_error(errors, _version, nil), do: errors

  defp maybe_add_pool_reference_error(errors, version, pool_id) do
    pool =
      AdapterPool
      |> where([pool], pool.id == ^pool_id)
      |> Repo.one()

    cond do
      is_nil(pool) ->
        [{:missing_adapter_pool, pool_id} | errors]

      pool.tenant_key != version.tenant_key and not is_nil(pool.tenant_key) ->
        [{:pool_tenant_mismatch, pool_id} | errors]

      pool_empty?(pool.id) ->
        [{:pool_empty, pool_id} | errors]

      true ->
        errors
    end
  end

  defp maybe_add_override_errors(errors, %{steps: steps}) do
    override_ids =
      steps
      |> Enum.map(& &1.adapter_override_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    adapters =
      ChannelAdapter
      |> where([adapter], adapter.id in ^override_ids)
      |> where([adapter], adapter.active)
      |> select([adapter], {adapter.id, adapter.channel})
      |> Repo.all()
      |> Map.new()

    Enum.reduce(steps, errors, fn step, acc ->
      add_override_error(step, adapters, acc)
    end)
  end

  defp add_override_error(%Step{adapter_override_id: nil}, _adapters, errors), do: errors

  defp add_override_error(%Step{adapter_override_id: adapter_id} = step, adapters, errors) do
    case Map.fetch(adapters, adapter_id) do
      :error ->
        [{:step, step.id, :missing_adapter_override} | errors]

      {:ok, channel} when channel != step.channel ->
        [{:step, step.id, :override_channel_mismatch} | errors]

      {:ok, _channel} ->
        errors
    end
  end

  defp pool_empty?(pool_id) do
    AdapterPoolMember
    |> where([member], member.pool_id == ^pool_id)
    |> where([member], member.active)
    |> Repo.repo!().aggregate(:count) == 0
  end

  defp pool_id(%{"pool_id" => pool_id}) when is_binary(pool_id), do: pool_id
  defp pool_id(%{pool_id: pool_id}) when is_binary(pool_id), do: pool_id
  defp pool_id(_config), do: nil

  defp add_adapter_errors_for_step(step, errors, adapters) do
    Enum.reduce(step_adapter_ids(step), errors, fn adapter_id, acc ->
      adapter_error(step, adapter_id, adapters, acc)
    end)
  end

  defp adapter_error(step, adapter_id, adapters, errors) do
    case Map.fetch(adapters, adapter_id) do
      :error ->
        [{:missing_channel_adapter, step.key, adapter_id} | errors]

      {:ok, channel} when channel != step.channel ->
        [{:adapter_channel_mismatch, step.key, adapter_id} | errors]

      {:ok, _channel} ->
        errors
    end
  end

  defp step_adapter_ids(step) do
    [step.channel_adapter_id, step.adapter_override_id]
    |> Enum.concat(rotation_adapter_ids(step.config || %{}))
    |> Enum.reject(&is_nil/1)
  end

  defp rotation_adapter_ids(%{"channel_adapter_rotation" => rotation}),
    do: normalize_rotation_adapter_ids(rotation)

  defp rotation_adapter_ids(%{channel_adapter_rotation: rotation}),
    do: normalize_rotation_adapter_ids(rotation)

  defp rotation_adapter_ids(_config), do: []

  defp normalize_rotation_adapter_ids(rotation) when is_list(rotation) do
    Enum.flat_map(rotation, fn
      %{"adapter_id" => adapter_id} -> [adapter_id]
      %{adapter_id: adapter_id} -> [adapter_id]
      adapter_id when is_binary(adapter_id) -> [adapter_id]
      _entry -> []
    end)
  end

  defp normalize_rotation_adapter_ids(_rotation), do: []

  defp maybe_add_condition_errors(errors, version) do
    version
    |> conditions()
    |> Enum.reduce(errors, fn condition, acc ->
      condition_errors(condition) ++ acc
    end)
  end

  defp condition_errors(%{condition_type: "enrollment_data"} = condition) do
    []
    |> require_field(condition, :field_path)
    |> require_field(condition, :expected_value)
    |> maybe_add_operator_error(condition)
  end

  defp condition_errors(%{condition_type: "event"} = condition) do
    []
    |> require_field(condition, :expected_value)
    |> maybe_add_operator_error(condition)
  end

  defp condition_errors(%{condition_type: "hook"} = condition) do
    errors = maybe_add_operator_error([], condition)

    if condition.hook_function || condition.http_hook_id do
      errors
    else
      [{:invalid_condition, condition.id, :missing_hook_reference} | errors]
    end
  end

  defp condition_errors(%{condition_type: "predicate"} = condition) do
    predicate =
      get_in(condition.config || %{}, ["predicate"]) ||
        get_in(condition.config || %{}, [:predicate])

    case Predicate.validate(predicate) do
      :ok -> []
      {:error, reason} -> [{:invalid_condition, condition.id, {:predicate, reason}}]
    end
  end

  defp condition_errors(condition), do: maybe_add_operator_error([], condition)

  defp maybe_add_operator_error(errors, %{operator: operator})
       when operator in ~w(== != > < >= <= in contains),
       do: errors

  defp maybe_add_operator_error(errors, condition),
    do: [{:invalid_condition, condition.id, {:operator, condition.operator}} | errors]

  defp require_field(errors, condition, field) do
    if Map.get(condition, field) in [nil, ""] do
      [{:invalid_condition, condition.id, {:missing, field}} | errors]
    else
      errors
    end
  end

  defp maybe_add_hook_reference_errors(errors, version) do
    conditions = conditions(version)

    errors
    |> maybe_add_http_hook_errors(version, conditions)
    |> maybe_add_module_hook_errors(version, conditions)
  end

  defp maybe_add_http_hook_errors(errors, version, conditions) do
    hook_ids =
      conditions
      |> Enum.map(& &1.http_hook_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    hooks =
      HttpHook
      |> where([hook], hook.id in ^hook_ids)
      |> where([hook], hook.sequence_id == ^version.sequence_id)
      |> select([hook], hook.id)
      |> Repo.all()
      |> MapSet.new()

    Enum.reduce(hook_ids, errors, fn hook_id, acc ->
      if MapSet.member?(hooks, hook_id), do: acc, else: [{:missing_http_hook, hook_id} | acc]
    end)
  end

  defp maybe_add_module_hook_errors(errors, version, conditions) do
    hook_functions =
      conditions
      |> Enum.map(& &1.hook_function)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.reduce(hook_functions, errors, fn hook_function, acc ->
      case hook_resolves?(version.sequence, hook_function) do
        :ok -> acc
        {:error, reason} -> [{:missing_hook_function, hook_function, reason} | acc]
      end
    end)
  end

  defp hook_resolves?(%{hook_module: hook_module}, hook_function) do
    with {:ok, module} <- module_from_string(hook_module),
         {:ok, function} <- Helpers.existing_atom(hook_function),
         true <- function_exported?(module, :handle_hook, 3),
         true <- is_atom(function) do
      :ok
    else
      false -> {:error, :missing_handle_hook}
      {:error, reason} -> {:error, reason}
    end
  end

  defp module_from_string(module), do: Helpers.module_from_string(module, :missing_hook_module)

  defp conditions(%{steps: steps, transitions: transitions}) do
    step_conditions = Enum.flat_map(steps, &Map.get(&1, :conditions, []))
    transition_conditions = Enum.flat_map(transitions, &Map.get(&1, :conditions, []))

    step_conditions ++ transition_conditions
  end

  defp validate_raw_cron(errors, key, expr) do
    case Parser.parse(expr) do
      {:ok, _cron} -> errors
      {:error, reason} -> [{:invalid_cron, key, reason} | errors]
    end
  end

  defp maybe_add_template_errors(errors, %{steps: steps}) do
    Enum.reduce(steps, errors, fn step, acc ->
      case Templates.validate(step.template_content, step.channel) do
        :ok -> acc
        {:error, reasons} -> [{:invalid_template, step.key, reasons} | acc]
      end
    end)
  end
end
