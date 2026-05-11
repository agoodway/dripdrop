defmodule DripdropDemo.Jobs.PruneSequenceRuns do
  @moduledoc """
  Nightly cleanup job for old demo sequence runtime data.

  The job only targets run-time rows created by the three public demo scenarios.
  It leaves sequence definitions, versions, steps, transitions, conditions, hooks,
  adapters, and pools intact so the demo can keep enrolling new visitors.
  """

  alias DripdropDemo.Repo
  alias Ecto.Adapters.SQL
  alias PgFlow.Queries.Flows

  use PgFlow.Job

  @tenant_key "demo"
  @retention_hours 24
  @sequence_keys ["onboarding", "lead-nurture", "outbound-campaigns"]
  @pgflow_flow_slugs ["dispatch_step", "cron_tick", "prune_sequence_runs"]

  @job queue: :prune_sequence_runs,
       cron: [schedule: "0 3 * * *"],
       max_attempts: 1,
       timeout: 60

  perform do
    fn _input, _ctx ->
      {:ok, dripdrop_counts} = prune_dripdrop_runtime()

      {:ok, pgflow_counts} =
        Flows.prune_data(Repo, retention_hours(), flow_slugs: @pgflow_flow_slugs)

      %{
        "dripdrop" => stringify_keys(dripdrop_counts),
        "pgflow" => stringify_keys(pgflow_counts)
      }
    end
  end

  import PgFlow.Job, except: [perform: 1, perform: 2]

  @doc """
  Prunes old runtime rows for the demo's seeded sequence examples.

  Only completed or cancelled enrollments older than the configured retention
  window are removed. Linked message events, short links, and subscriber events
  are deleted first so they do not survive as orphaned audit rows.
  """
  @spec prune_dripdrop_runtime(module(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def prune_dripdrop_runtime(repo \\ Repo, retention_hours \\ retention_hours()) do
    cutoff = DateTime.add(DateTime.utc_now(), -retention_hours, :hour)

    sql = """
    WITH old_enrollments AS (
      SELECT enrollments.id
      FROM dripdrop.enrollments AS enrollments
      INNER JOIN dripdrop.sequences AS sequences
        ON sequences.id = enrollments.sequence_id
      WHERE enrollments.tenant_key = $1
        AND sequences.key = ANY($2::text[])
        AND enrollments.started_at < $3
        AND enrollments.state IN ('completed', 'cancelled')
    ),
    old_executions AS (
      SELECT step_executions.id
      FROM dripdrop.step_executions AS step_executions
      WHERE step_executions.enrollment_id IN (SELECT id FROM old_enrollments)
    ),
    deleted_message_events AS (
      DELETE FROM dripdrop.message_events
      WHERE step_execution_id IN (SELECT id FROM old_executions)
      RETURNING 1
    ),
    deleted_short_links AS (
      DELETE FROM dripdrop.short_links
      WHERE step_execution_id IN (SELECT id FROM old_executions)
      RETURNING 1
    ),
    deleted_events AS (
      DELETE FROM dripdrop.events
      WHERE enrollment_id IN (SELECT id FROM old_enrollments)
      RETURNING 1
    ),
    deleted_enrollments AS (
      DELETE FROM dripdrop.enrollments
      WHERE id IN (SELECT id FROM old_enrollments)
      RETURNING 1
    )
    SELECT
      (SELECT count(*) FROM old_executions) AS deleted_step_executions,
      (SELECT count(*) FROM deleted_message_events) AS deleted_message_events,
      (SELECT count(*) FROM deleted_short_links) AS deleted_short_links,
      (SELECT count(*) FROM deleted_events) AS deleted_events,
      (SELECT count(*) FROM deleted_enrollments) AS deleted_enrollments
    """

    case SQL.query(repo, sql, [@tenant_key, @sequence_keys, cutoff]) do
      {:ok, %{rows: [[executions, message_events, short_links, events, enrollments]]}} ->
        {:ok,
         %{
           deleted_step_executions: executions,
           deleted_message_events: message_events,
           deleted_short_links: short_links,
           deleted_events: events,
           deleted_enrollments: enrollments
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the demo sequence retention window in hours.
  """
  @spec retention_hours() :: pos_integer()
  def retention_hours do
    Application.get_env(:dripdrop_demo, :sequence_run_retention_hours, @retention_hours)
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
