defmodule DripDrop.Enrollments do
  @moduledoc """
  Enrollment lifecycle context.
  """

  import Ecto.Query

  alias Ecto.Multi

  alias DripDrop.{
    Clock,
    Enrollment,
    Event,
    Helpers,
    Repo,
    Scheduler,
    Sequence,
    SequenceVersion,
    Step,
    StepExecution,
    TenantScope
  }

  alias DripDrop.Dispatch.Idempotency
  alias DripDrop.Dispatch.Steps, as: DispatchSteps

  @spec enroll(map()) :: {:ok, Ecto.Schema.t()} | {:error, term()}
  @doc """
  Enrolls a subscriber into the active sequence version and schedules the first step.
  """
  def enroll(attrs) when is_list(attrs), do: attrs |> Map.new() |> enroll()

  def enroll(attrs) when is_map(attrs) do
    repo = Repo.repo!()

    with {:ok, sequence} <- sequence_from_attrs(repo, attrs),
         :ok <- tenant_matches?(sequence, attr(attrs, :tenant_key)),
         {:ok, subscriber_type, subscriber_id} <- subscriber_identity(attrs),
         nil <- active_or_paused_enrollment(repo, sequence.id, subscriber_type, subscriber_id),
         :ok <- reenrollment_allowed?(repo, sequence, subscriber_type, subscriber_id) do
      do_enroll(repo, sequence, subscriber_type, subscriber_id, attrs)
    else
      %Enrollment{} = enrollment -> {:ok, enrollment}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_enroll(repo, sequence, subscriber_type, subscriber_id, attrs) do
    version = active_version!(repo, sequence.id)
    first_step = first_step!(repo, version.id, attr(attrs, :starting_step_key))
    scheduled_for = scheduled_for(first_step)

    enrollment_changeset =
      %Enrollment{}
      |> Enrollment.changeset(
        attrs
        |> normalize_attrs()
        |> Map.put(:sequence_id, sequence.id)
        |> Map.put(:sequence_version_id, version.id)
        |> Map.put(:tenant_key, sequence.tenant_key)
        |> Map.put(:subscriber_type, subscriber_type)
        |> Map.put(:subscriber_id, subscriber_id)
        |> Map.put_new(:state, "active")
        |> Map.put_new(:started_at, Clock.now())
      )

    Multi.new()
    |> Multi.insert(:enrollment, enrollment_changeset)
    |> Multi.insert(:step_execution, fn %{enrollment: enrollment} ->
      step_execution_changeset(enrollment, first_step, scheduled_for)
    end)
    |> Multi.run(:schedule, fn _repo, %{step_execution: execution} ->
      Scheduler.configured().schedule(execution, scheduled_for)
    end)
    |> Multi.update(:scheduled_step_execution, fn %{step_execution: execution, schedule: job_id} ->
      StepExecution.changeset(execution, %{
        scheduler_job_id: job_id_to_string(job_id),
        scheduler_backend: Scheduler.configured_name()
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{enrollment: enrollment}} -> {:ok, enrollment}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @spec pause_enrollment(Ecto.UUID.t()) :: no_return()
  @doc """
  Deprecated unscoped pause. Use `pause_enrollment/2` with an explicit tenant key.
  """
  def pause_enrollment(enrollment_id) do
    _unused = enrollment_id
    TenantScope.raise_missing!(:pause_enrollment)
  end

  @spec pause_enrollment(Ecto.UUID.t(), binary() | nil) ::
          {:ok, Ecto.Schema.t()} | {:error, term()}
  @doc """
  Pauses an enrollment scoped by tenant and cancels any pending scheduled executions.
  """
  def pause_enrollment(enrollment_id, tenant_key),
    do: transition_with_pending_cancellation(enrollment_id, tenant_key, "paused")

  @spec resume_enrollment(Ecto.UUID.t()) :: no_return()
  @doc """
  Deprecated unscoped resume. Use `resume_enrollment/2` with an explicit tenant key.
  """
  def resume_enrollment(enrollment_id) do
    _unused = enrollment_id
    TenantScope.raise_missing!(:resume_enrollment)
  end

  @spec resume_enrollment(Ecto.UUID.t(), binary() | nil) ::
          {:ok, Ecto.Schema.t()} | {:error, term()}
  @doc """
  Resumes a paused enrollment scoped by tenant and schedules the next unsent step.
  """
  def resume_enrollment(enrollment_id, tenant_key) do
    repo = Repo.repo!()
    enrollment = fetch_scoped_enrollment!(repo, enrollment_id, tenant_key)
    changeset = Enrollment.transition_changeset(enrollment, "active")

    if invalid_transition?(changeset) do
      {:error, :invalid_transition}
    else
      do_resume_enrollment(changeset)
    end
  end

  defp do_resume_enrollment(changeset) do
    Multi.new()
    |> Multi.update(:enrollment, changeset)
    |> Multi.run(:reschedule, fn _repo, %{enrollment: resumed} ->
      reschedule_next_step(resumed)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{enrollment: enrollment}} -> {:ok, enrollment}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @spec unenroll(Ecto.UUID.t()) :: no_return()
  @doc """
  Deprecated unscoped cancel. Use `unenroll/2` with an explicit tenant key.
  """
  def unenroll(enrollment_id) do
    _unused = enrollment_id
    TenantScope.raise_missing!(:unenroll)
  end

  @spec unenroll(Ecto.UUID.t(), binary() | nil) ::
          {:ok, Ecto.Schema.t()} | {:error, term()}
  @doc """
  Cancels an enrollment scoped by tenant and any pending scheduled executions.
  """
  def unenroll(enrollment_id, tenant_key),
    do: transition_with_pending_cancellation(enrollment_id, tenant_key, "cancelled")

  @spec track_event(Ecto.UUID.t(), binary(), map()) :: no_return()
  @doc """
  Deprecated unscoped event tracking by enrollment id. Use `track_event/4`.
  """
  def track_event(enrollment_id, event_key, event_data) when is_binary(enrollment_id) do
    _unused = {enrollment_id, event_key, event_data}
    TenantScope.raise_missing!(:track_event)
  end

  def track_event(%{} = subscriber, event_key, event_data) do
    %Event{}
    |> Event.changeset(%{
      tenant_key: Map.get(subscriber, :tenant_key) || Map.get(subscriber, "tenant_key"),
      subscriber_type:
        Map.get(subscriber, :subscriber_type) || Map.get(subscriber, "subscriber_type"),
      subscriber_id: Map.get(subscriber, :subscriber_id) || Map.get(subscriber, "subscriber_id"),
      event_key: event_key,
      event_data: Helpers.stringify_keys(event_data),
      occurred_at: Clock.now()
    })
    |> Repo.insert()
    |> schedule_event_steps(event_key)
  end

  @spec track_event(Ecto.UUID.t(), binary(), map(), binary() | nil) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Records a subscriber event for a tenant-scoped enrollment and schedules
  matching event-triggered steps. Raises if the enrollment is not in the
  given tenant scope.
  """
  def track_event(enrollment_id, event_key, event_data, tenant_key)
      when is_binary(enrollment_id) do
    enrollment = fetch_scoped_enrollment!(Repo.repo!(), enrollment_id, tenant_key)

    %Event{}
    |> Event.changeset(%{
      enrollment_id: enrollment_id,
      tenant_key: enrollment.tenant_key,
      subscriber_type: enrollment.subscriber_type,
      subscriber_id: enrollment.subscriber_id,
      event_key: event_key,
      event_data: Helpers.stringify_keys(event_data),
      occurred_at: Clock.now()
    })
    |> Repo.insert()
    |> schedule_event_steps(event_key)
  end

  @spec list_active_enrollments(map()) :: [Ecto.Schema.t()]
  @doc """
  Lists active enrollments with an explicit tenant scope and optional sequence filter.
  """
  def list_active_enrollments(filters \\ %{}) do
    tenant_key = TenantScope.fetch!(filters, :list_active_enrollments)

    Enrollment
    |> where([enrollment], enrollment.state == "active")
    |> where_tenant_scope(tenant_key)
    |> maybe_filter(:sequence_id, Map.get(filters, :sequence_id))
    |> Repo.all()
  end

  @spec get_enrollment(Ecto.UUID.t(), binary(), binary()) :: no_return()
  @doc """
  Deprecated unscoped lookup. Use `get_enrollment/4` with an explicit tenant key.
  """
  def get_enrollment(sequence_id, subscriber_type, subscriber_id) do
    _unused = {sequence_id, subscriber_type, subscriber_id}
    TenantScope.raise_missing!(:get_enrollment)
  end

  @spec get_enrollment(Ecto.UUID.t(), binary(), binary(), binary() | nil) :: Ecto.Schema.t() | nil
  @doc """
  Finds one enrollment by sequence, subscriber identity, and explicit tenant scope.
  """
  def get_enrollment(sequence_id, subscriber_type, subscriber_id, tenant_key) do
    Enrollment
    |> where([enrollment], enrollment.sequence_id == ^sequence_id)
    |> where([enrollment], enrollment.subscriber_type == ^subscriber_type)
    |> where([enrollment], enrollment.subscriber_id == ^subscriber_id)
    |> where_tenant_scope(tenant_key)
    |> limit(1)
    |> Repo.one()
  end

  defp transition_with_pending_cancellation(enrollment_id, tenant_key, next_state) do
    repo = Repo.repo!()
    enrollment = fetch_scoped_enrollment!(repo, enrollment_id, tenant_key)
    changeset = Enrollment.transition_changeset(enrollment, next_state)

    if invalid_transition?(changeset) do
      {:error, :invalid_transition}
    else
      Multi.new()
      |> Multi.run(:cancel_scheduler_jobs, fn _repo, _changes ->
        cancel_pending_scheduler_jobs(enrollment.id)
      end)
      |> Multi.update_all(:cancel_pending_executions, pending_execution_query(enrollment.id),
        set: [state: "cancelled", updated_at: Clock.now()]
      )
      |> Multi.update(:enrollment, changeset)
      |> Repo.transaction()
      |> case do
        {:ok, %{enrollment: enrollment}} -> {:ok, enrollment}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  defp step_execution_changeset(enrollment, step, scheduled_for) do
    idempotency_key = Idempotency.key(enrollment.id, step.id, scheduled_for, 0)

    StepExecution.changeset(%StepExecution{}, %{
      enrollment_id: enrollment.id,
      step_id: step.id,
      tenant_key: enrollment.tenant_key,
      scheduled_for: scheduled_for,
      idempotency_key: idempotency_key,
      channel: step.channel,
      recipient: recipient(enrollment, step)
    })
  end

  defp active_version!(repo, sequence_id) do
    repo.one!(
      from(version in SequenceVersion,
        where: version.sequence_id == ^sequence_id,
        where: version.state == "active",
        limit: 1
      )
    )
  end

  defp first_step!(repo, version_id, nil) do
    repo.one!(
      from(step in Step,
        where: step.sequence_version_id == ^version_id,
        order_by: [asc: step.position],
        limit: 1
      )
    )
  end

  defp first_step!(repo, version_id, step_key) do
    repo.one!(
      from(step in Step,
        where: step.sequence_version_id == ^version_id,
        where: step.key == ^step_key,
        limit: 1
      )
    )
  end

  defp scheduled_for(%Step{timing: timing}) do
    Helpers.scheduled_for(timing)
  end

  defp recipient(enrollment, step) do
    recipient_key = get_in(step.config || %{}, ["recipient_key"]) || step.channel
    Map.get(enrollment.data || %{}, recipient_key)
  end

  defp reschedule_next_step(%Enrollment{} = enrollment) do
    repo = Repo.repo!()

    next_step =
      from(step in Step, as: :step)
      |> where([step: step], step.sequence_version_id == ^enrollment.sequence_version_id)
      |> where(
        [step: step],
        not exists(
          from(execution in StepExecution,
            where: execution.enrollment_id == ^enrollment.id,
            where: execution.step_id == parent_as(:step).id,
            where: execution.state in ["sent", "skipped", "sending", "claiming"]
          )
        )
      )
      |> order_by([step: step], asc: step.position)
      |> limit(1)
      |> repo.one()

    case next_step do
      nil ->
        {:ok, :no_step_to_reschedule}

      %Step{} = step ->
        DispatchSteps.schedule(enrollment, step,
          attempt_window: next_attempt_window(enrollment, step)
        )
    end
  end

  defp schedule_event_steps({:ok, %Event{} = event}, event_key) do
    errors =
      event
      |> matching_event_steps(event_key)
      |> Enum.reduce([], fn step, errors ->
        case DispatchSteps.seed_for_step(step, Clock.now(), event_filters(event)) do
          {:ok, _executions} ->
            errors

          {:error, reason} ->
            require Logger

            Logger.error(
              "[dripdrop] Enrollments.schedule_event_steps failed step=#{step.id}: #{inspect(reason)}"
            )

            [{step.id, reason} | errors]
        end
      end)

    if errors == [] do
      {:ok, event}
    else
      :telemetry.execute(
        [:dripdrop, :enrollments, :event_seed, :error],
        %{count: length(errors)},
        %{errors: errors}
      )

      {:ok, event}
    end
  end

  defp schedule_event_steps(error, _event_key), do: error

  defp matching_event_steps(%Event{tenant_key: tenant_key}, event_key) do
    Step
    |> where([step], fragment("?->>'type' = 'event'", step.timing))
    |> where([step], fragment("?->>'trigger_event' = ?", step.timing, ^event_key))
    |> where_step_tenant(tenant_key)
    |> Repo.all()
  end

  defp where_step_tenant(query, nil), do: where(query, [step], is_nil(step.tenant_key))

  defp where_step_tenant(query, tenant_key),
    do: where(query, [step], step.tenant_key == ^tenant_key)

  defp event_filters(%Event{enrollment_id: enrollment_id}) when not is_nil(enrollment_id),
    do: [enrollment_id: enrollment_id]

  defp event_filters(%Event{} = event) do
    [
      subscriber_type: event.subscriber_type,
      subscriber_id: event.subscriber_id,
      tenant_key: event.tenant_key
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp pending_execution_query(enrollment_id) do
    from(execution in StepExecution,
      where: execution.enrollment_id == ^enrollment_id,
      where: execution.state == "scheduled"
    )
  end

  defp next_attempt_window(enrollment, step) do
    repo = Repo.repo!()

    StepExecution
    |> where([execution], execution.enrollment_id == ^enrollment.id)
    |> where([execution], execution.step_id == ^step.id)
    |> repo.aggregate(:max, :attempt_window)
    |> case do
      attempt_window when is_integer(attempt_window) -> attempt_window + 1
      _other -> 0
    end
  end

  defp cancel_pending_scheduler_jobs(enrollment_id) do
    enrollment_id
    |> pending_execution_query()
    |> Repo.all()
    |> Enum.reduce_while(:ok, fn execution, :ok ->
      case cancel_scheduler_job(execution) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      :ok -> {:ok, :cancelled}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, field, value), do: where(query, [row], field(row, ^field) == ^value)

  defp where_tenant_scope(query, nil), do: where(query, [row], is_nil(row.tenant_key))

  defp where_tenant_scope(query, tenant_key),
    do: where(query, [row], row.tenant_key == ^tenant_key)

  defp fetch_scoped_enrollment!(repo, enrollment_id, tenant_key) do
    query =
      Enrollment
      |> where([e], e.id == ^enrollment_id)
      |> where_tenant_scope(tenant_key)
      |> limit(1)

    case repo.one(query) do
      %Enrollment{} = enrollment -> enrollment
      nil -> raise Ecto.NoResultsError, queryable: Enrollment
    end
  end

  defp sequence_from_attrs(repo, attrs) do
    cond do
      sequence_id = attr(attrs, :sequence_id) ->
        {:ok, repo.get!(Sequence, sequence_id)}

      sequence_key = attr(attrs, :sequence_key) || attr(attrs, :key) ->
        sequence_by_key(repo, sequence_key, attr(attrs, :tenant_key))

      true ->
        {:error, :missing_sequence}
    end
  end

  defp sequence_by_key(repo, sequence_key, tenant_key) do
    query =
      Sequence
      |> where([sequence], sequence.key == ^sequence_key)
      |> sequence_tenant_filter(tenant_key)
      |> limit(1)

    case repo.one(query) do
      %Sequence{} = sequence ->
        {:ok, sequence}

      nil ->
        if sequence_key_exists?(repo, sequence_key) do
          {:error, :tenant_mismatch}
        else
          {:error, :missing_sequence}
        end
    end
  end

  defp sequence_tenant_filter(query, nil),
    do: where(query, [sequence], is_nil(sequence.tenant_key))

  defp sequence_tenant_filter(query, tenant_key),
    do: where(query, [sequence], sequence.tenant_key == ^tenant_key)

  defp sequence_key_exists?(repo, sequence_key) do
    repo.exists?(from(sequence in Sequence, where: sequence.key == ^sequence_key))
  end

  defp tenant_matches?(%Sequence{tenant_key: nil}, _tenant_key), do: :ok
  defp tenant_matches?(%Sequence{tenant_key: tenant_key}, tenant_key), do: :ok
  defp tenant_matches?(%Sequence{}, _tenant_key), do: {:error, :tenant_mismatch}

  defp subscriber_identity(attrs) do
    subscriber = attr(attrs, :subscriber) || %{}
    type = attr(subscriber, :type) || attr(attrs, :subscriber_type)
    id = attr(subscriber, :id) || attr(attrs, :subscriber_id)

    if present?(type) and present?(id) do
      {:ok, to_string(type), to_string(id)}
    else
      {:error, :missing_subscriber}
    end
  end

  defp active_or_paused_enrollment(repo, sequence_id, subscriber_type, subscriber_id) do
    repo.one(
      from(enrollment in Enrollment,
        where: enrollment.sequence_id == ^sequence_id,
        where: enrollment.subscriber_type == ^subscriber_type,
        where: enrollment.subscriber_id == ^subscriber_id,
        where: enrollment.state in ["active", "paused"],
        order_by: [desc: enrollment.inserted_at],
        limit: 1
      )
    )
  end

  defp reenrollment_allowed?(repo, sequence, subscriber_type, subscriber_id) do
    terminal_exists? =
      repo.exists?(
        from(enrollment in Enrollment,
          where: enrollment.sequence_id == ^sequence.id,
          where: enrollment.subscriber_type == ^subscriber_type,
          where: enrollment.subscriber_id == ^subscriber_id,
          where: enrollment.state in ["completed", "cancelled"]
        )
      )

    if terminal_exists? and not allow_reenrollment?(sequence) do
      {:error, :reenrollment_not_allowed}
    else
      :ok
    end
  end

  defp allow_reenrollment?(%{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "allow_reenrollment") || Map.get(metadata, :allow_reenrollment) || false
  end

  defp normalize_attrs(attrs) do
    attrs
    |> Map.drop([:subscriber, "subscriber", :sequence_key, "sequence_key", :key, "key"])
    |> Map.new(fn {key, value} -> {Helpers.atom_or_string(key), value} end)
  end

  defp attr(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp attr(_map, _key), do: nil

  defp present?(value), do: value not in [nil, ""]

  defp invalid_transition?(changeset), do: "invalid transition" in errors_on(changeset, :state)

  defp errors_on(changeset, field) do
    changeset.errors
    |> Keyword.get_values(field)
    |> Enum.map(fn {message, _opts} -> message end)
  end

  defp job_id_to_string(job_id) when is_binary(job_id), do: job_id
  defp job_id_to_string(job_id) when is_integer(job_id), do: Integer.to_string(job_id)
  defp job_id_to_string(job_id), do: inspect(job_id)

  defp cancel_scheduler_job(%StepExecution{scheduler_job_id: nil}), do: :ok

  defp cancel_scheduler_job(%StepExecution{
         scheduler_job_id: job_id,
         scheduler_backend: backend
       })
       when is_binary(backend) do
    case Scheduler.module_for_backend(backend) do
      {:ok, module} -> module.cancel(job_id)
      {:error, _} -> :ok
    end
  end

  defp cancel_scheduler_job(%StepExecution{scheduler_job_id: job_id}) do
    Scheduler.configured().cancel(job_id)
  end
end
