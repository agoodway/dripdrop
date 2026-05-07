defmodule DripDrop.Dispatch.Steps do
  @moduledoc """
  Creates and enqueues step execution rows for enrollments.
  """

  alias DripDrop.{Clock, DBHelpers, Enrollment, Helpers, Repo, Scheduler, Step, StepExecution}
  alias DripDrop.Dispatch.Idempotency
  alias Ecto.UUID
  import Ecto.Query

  @schema Application.compile_env(:dripdrop, :schema, "dripdrop")
  @reschedulable_states ~w(claiming sending failed scheduled)

  @doc """
  Creates and enqueues one step execution for an enrollment.
  """
  @spec schedule(Ecto.Schema.t(), Ecto.Schema.t(), keyword()) ::
          {:ok, Ecto.Schema.t()} | {:error, term()}
  def schedule(%Enrollment{} = enrollment, %Step{} = step, opts \\ []) do
    scheduled_for = Keyword.get_lazy(opts, :scheduled_for, fn -> scheduled_for(step) end)
    attempt_window = Keyword.get(opts, :attempt_window, 0)
    idempotency_key = Idempotency.key(enrollment.id, step.id, scheduled_for, attempt_window)

    attrs = %{
      enrollment_id: enrollment.id,
      step_id: step.id,
      tenant_key: enrollment.tenant_key,
      scheduled_for: scheduled_for,
      idempotency_key: idempotency_key,
      attempt_window: attempt_window,
      channel: step.channel,
      recipient: recipient(enrollment, step)
    }

    with {:ok, execution} <- %StepExecution{} |> StepExecution.changeset(attrs) |> Repo.insert(),
         {:ok, job_id} <- Scheduler.configured().schedule(execution, scheduled_for) do
      execution
      |> StepExecution.changeset(%{
        scheduler_job_id: job_id_to_string(job_id),
        scheduler_backend: scheduler_backend()
      })
      |> Repo.update()
    end
  end

  @doc """
  Moves a step execution back to scheduled state at a new time.
  """
  @spec reschedule(Ecto.Schema.t(), DateTime.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, term()}
  def reschedule(%StepExecution{} = execution, %DateTime{} = scheduled_for) do
    query =
      from(e in StepExecution,
        where: e.id == ^execution.id and e.state in ^@reschedulable_states
      )

    case Repo.update_all(query,
           set: [
             state: "scheduled",
             scheduled_for: scheduled_for,
             claimed_at: nil,
             updated_at: Clock.now()
           ]
         ) do
      {0, _} ->
        {:error, :state_changed}

      {1, _} ->
        with reloaded <- Repo.get!(StepExecution, execution.id),
             {:ok, job_id} <- Scheduler.configured().schedule(reloaded, scheduled_for),
             :ok <-
               cancel_previous_scheduler_job(
                 execution.scheduler_job_id,
                 execution.scheduler_backend
               ) do
          reloaded
          |> StepExecution.changeset(%{
            scheduler_job_id: job_id_to_string(job_id),
            scheduler_backend: scheduler_backend()
          })
          |> Repo.update()
        end
    end
  end

  defp cancel_previous_scheduler_job(nil, _backend), do: :ok

  defp cancel_previous_scheduler_job(_job_id, nil) do
    # No backend recorded means it was scheduled before scheduler_backend writes existed.
    # Best-effort: skip cancel. Idempotency unique key catches any double-fire downstream.
    :ok
  end

  defp cancel_previous_scheduler_job(job_id, backend) do
    case Scheduler.module_for_backend(backend) do
      {:ok, module} ->
        case module.cancel(job_id) do
          :ok -> :ok
          {:error, _reason} -> :ok
        end

      {:error, _} ->
        :ok
    end
  end

  defp scheduler_backend, do: Scheduler.configured_name()

  @doc """
  Bulk seeds executions for active enrollments eligible for a step.
  """
  @spec seed_for_step(Ecto.Schema.t(), DateTime.t(), keyword()) ::
          {:ok, [Ecto.Schema.t()]} | {:error, term()}
  def seed_for_step(%Step{} = step, %DateTime{} = scheduled_for, opts \\ []) do
    with {:ok, ids} <- insert_seed_rows(step, scheduled_for, opts) do
      enqueue_seed_rows(ids, scheduled_for)
    end
  end

  @doc """
  Calculates the next scheduled time for a step from its timing config.
  """
  @spec scheduled_for(Ecto.Schema.t()) :: DateTime.t()
  def scheduled_for(%Step{timing: timing}) do
    Helpers.scheduled_for(timing)
  end

  defp recipient(enrollment, step) do
    recipient_key = get_in(step.config || %{}, ["recipient_key"]) || step.channel
    Map.get(enrollment.data || %{}, recipient_key)
  end

  defp job_id_to_string(job_id) when is_binary(job_id), do: job_id
  defp job_id_to_string(job_id) when is_integer(job_id), do: Integer.to_string(job_id)
  defp job_id_to_string(job_id), do: inspect(job_id)

  defp insert_seed_rows(step, scheduled_for, opts) do
    schema = @schema
    recipient_key = get_in(step.config || %{}, ["recipient_key"]) || step.channel
    opts_without_tenant = Keyword.delete(opts, :tenant_key)
    {filters_sql, filter_params} = enrollment_filters(opts_without_tenant)

    sql = """
    INSERT INTO #{schema}.step_executions (
      enrollment_id,
      step_id,
      tenant_key,
      state,
      scheduled_for,
      retry_count,
      attempt_window,
      idempotency_key,
      channel,
      recipient,
      metadata,
      inserted_at,
      updated_at
    )
    SELECT
      enrollments.id,
      $1::uuid,
      enrollments.tenant_key,
      'scheduled',
      $2::timestamptz,
      0,
      $3::integer,
      #{Idempotency.sql_call(schema, "enrollments.id")},
      $4::text,
      enrollments.data->>$5::text,
      '{}'::jsonb,
      now(),
      now()
    FROM #{schema}.enrollments
    WHERE enrollments.sequence_version_id = $6::uuid
      AND enrollments.state = 'active'
      AND enrollments.tenant_key IS NOT DISTINCT FROM $7::text
      #{filters_sql}
      AND NOT EXISTS (
        SELECT 1
        FROM #{schema}.step_executions existing
        WHERE existing.enrollment_id = enrollments.id
          AND existing.step_id = $1::uuid
          AND existing.scheduled_for = $2::timestamptz
      )
    ON CONFLICT (idempotency_key) DO NOTHING
    RETURNING id
    """

    params =
      [
        DBHelpers.dump_uuid(step.id),
        scheduled_for,
        0,
        step.channel,
        recipient_key,
        DBHelpers.dump_uuid(step.sequence_version_id),
        step.tenant_key
      ] ++ Enum.map(filter_params, &dump_filter_param/1)

    case Repo.query(sql, params) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [id] -> load_uuid(id) end)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp enqueue_seed_rows([], _scheduled_for), do: {:ok, []}

  defp enqueue_seed_rows(ids, scheduled_for) do
    executions =
      StepExecution
      |> where([execution], execution.id in ^ids)
      |> Repo.all()

    executions
    |> Enum.reduce_while({:ok, []}, fn execution, {:ok, acc} ->
      with {:ok, job_id} <- Scheduler.configured().schedule(execution, scheduled_for),
           {:ok, execution} <-
             execution
             |> StepExecution.changeset(%{
               scheduler_job_id: job_id_to_string(job_id),
               scheduler_backend: scheduler_backend()
             })
             |> Repo.update() do
        {:cont, {:ok, [execution | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, executions} -> {:ok, Enum.reverse(executions)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp enrollment_filters(opts) do
    [
      {:enrollment_id, "enrollments.id", "uuid"},
      {:subscriber_type, "enrollments.subscriber_type", "text"},
      {:subscriber_id, "enrollments.subscriber_id", "text"}
    ]
    |> Enum.reduce({[], [], 8}, fn {key, column, type}, {sql, params, index} ->
      case Keyword.get(opts, key) do
        nil -> {sql, params, index}
        value -> {["AND #{column} = $#{index}::#{type}" | sql], [value | params], index + 1}
      end
    end)
    |> then(fn {sql, params, _index} ->
      {sql |> Enum.reverse() |> Enum.join("\n"), Enum.reverse(params)}
    end)
  end

  defp dump_filter_param(value) when is_binary(value) do
    case UUID.dump(value) do
      {:ok, dumped} -> dumped
      :error -> value
    end
  end

  defp dump_filter_param(value), do: value

  defp load_uuid(<<_::128>> = id) do
    case UUID.load(id) do
      {:ok, uuid} -> uuid
      :error -> id
    end
  end

  defp load_uuid(id), do: id
end
