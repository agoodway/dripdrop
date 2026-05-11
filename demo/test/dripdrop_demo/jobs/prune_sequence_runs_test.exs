defmodule DripdropDemo.Jobs.PruneSequenceRunsTest do
  use DripdropDemo.DataCase

  alias DripdropDemo.Jobs.PruneSequenceRuns
  alias Ecto.Adapters.SQL

  describe "prune_dripdrop_runtime/2" do
    test "removes only old completed demo runs for the seeded scenario sequences" do
      old_demo = insert_run!("onboarding", "completed", hours_ago(48))
      fresh_demo = insert_run!("lead-nurture", "completed", hours_ago(1))
      active_demo = insert_run!("outbound-campaigns", "active", hours_ago(48))
      other_sequence = insert_run!("internal-test-sequence", "completed", hours_ago(48))

      assert {:ok,
              %{
                deleted_enrollments: 1,
                deleted_step_executions: 1,
                deleted_message_events: 1,
                deleted_short_links: 1,
                deleted_events: 1
              }} = PruneSequenceRuns.prune_dripdrop_runtime(Repo, 24)

      refute exists?("dripdrop.enrollments", old_demo.enrollment_id)
      refute exists?("dripdrop.step_executions", old_demo.step_execution_id)
      refute exists?("dripdrop.message_events", old_demo.message_event_id)
      refute exists?("dripdrop.short_links", old_demo.short_link_id)
      refute exists?("dripdrop.events", old_demo.event_id)

      assert exists?("dripdrop.sequences", old_demo.sequence_id)
      assert exists?("dripdrop.sequence_versions", old_demo.sequence_version_id)
      assert exists?("dripdrop.steps", old_demo.step_id)

      assert exists?("dripdrop.enrollments", fresh_demo.enrollment_id)
      assert exists?("dripdrop.enrollments", active_demo.enrollment_id)
      assert exists?("dripdrop.enrollments", other_sequence.enrollment_id)
    end
  end

  defp insert_run!(sequence_key, state, started_at) do
    suffix =
      System.unique_integer([:positive])
      |> Integer.to_string()

    completed_at = if state == "completed", do: started_at, else: nil
    cancelled_at = if state == "cancelled", do: started_at, else: nil

    sql = """
    WITH sequence AS (
      INSERT INTO dripdrop.sequences (tenant_key, name, key)
      VALUES ('demo', $1, $2)
      RETURNING id
    ),
    version AS (
      INSERT INTO dripdrop.sequence_versions (sequence_id, tenant_key, version, state)
      SELECT id, 'demo', 1, 'active'::dripdrop.sequence_version_state FROM sequence
      RETURNING id, sequence_id
    ),
    step AS (
      INSERT INTO dripdrop.steps (sequence_version_id, tenant_key, name, key, channel)
      SELECT id, 'demo', 'Demo step', 'demo-step-' || $3, 'email' FROM version
      RETURNING id, sequence_version_id
    ),
    enrollment AS (
      INSERT INTO dripdrop.enrollments (
        sequence_id,
        sequence_version_id,
        tenant_key,
        subscriber_type,
        subscriber_id,
        state,
        started_at,
        completed_at,
        cancelled_at
      )
      SELECT
        version.sequence_id,
        version.id,
        'demo',
        'contact',
        'contact-' || $3,
        $4::dripdrop.enrollment_state,
        $5,
        $6,
        $7
      FROM version
      RETURNING id, sequence_id, sequence_version_id
    ),
    execution AS (
      INSERT INTO dripdrop.step_executions (
        enrollment_id,
        step_id,
        tenant_key,
        state,
        scheduled_for,
        idempotency_key,
        channel
      )
      SELECT
        enrollment.id,
        step.id,
        'demo',
        'scheduled'::dripdrop.step_execution_state,
        $5,
        'idem-' || $3,
        'email'
      FROM enrollment, step
      RETURNING id, enrollment_id, step_id
    ),
    message_event AS (
      INSERT INTO dripdrop.message_events (
        step_execution_id,
        tenant_key,
        channel,
        provider,
        event_type,
        occurred_at
      )
      SELECT id, 'demo', 'email', 'demo', 'sent'::dripdrop.message_event_type, $5
      FROM execution
      RETURNING id
    ),
    short_link AS (
      INSERT INTO dripdrop.short_links (
        step_execution_id,
        tenant_key,
        provider,
        original_url,
        destination_url,
        idempotency_key
      )
      SELECT
        id,
        'demo',
        'demo',
        'https://example.com/original',
        'https://example.com/destination',
        'short-' || $3
      FROM execution
      RETURNING id
    ),
    event AS (
      INSERT INTO dripdrop.events (
        enrollment_id,
        tenant_key,
        subscriber_type,
        subscriber_id,
        event_key,
        occurred_at
      )
      SELECT id, 'demo', 'contact', 'contact-' || $3, 'demo.event', $5
      FROM enrollment
      RETURNING id
    )
    SELECT
      sequence.id,
      version.id,
      step.id,
      enrollment.id,
      execution.id,
      message_event.id,
      short_link.id,
      event.id
    FROM sequence, version, step, enrollment, execution, message_event, short_link, event
    """

    %{
      rows: [
        [
          sequence_id,
          sequence_version_id,
          step_id,
          enrollment_id,
          step_execution_id,
          message_event_id,
          short_link_id,
          event_id
        ]
      ]
    } =
      SQL.query!(Repo, sql, [
        "Demo #{sequence_key} #{suffix}",
        sequence_key,
        suffix,
        state,
        started_at,
        completed_at,
        cancelled_at
      ])

    %{
      sequence_id: sequence_id,
      sequence_version_id: sequence_version_id,
      step_id: step_id,
      enrollment_id: enrollment_id,
      step_execution_id: step_execution_id,
      message_event_id: message_event_id,
      short_link_id: short_link_id,
      event_id: event_id
    }
  end

  defp exists?(table, id) do
    sql = "SELECT EXISTS(SELECT 1 FROM #{table} WHERE id = $1)"

    case SQL.query!(Repo, sql, [id]) do
      %{rows: [[true]]} -> true
      %{rows: [[false]]} -> false
    end
  end

  defp hours_ago(hours) do
    DateTime.utc_now()
    |> DateTime.add(-hours, :hour)
    |> DateTime.truncate(:second)
  end
end
