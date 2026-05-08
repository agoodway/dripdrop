defmodule DripDrop.DatabaseSmokeTest do
  use DripDrop.DataCase, async: true

  alias DripDrop.TestRepo

  describe "test database" do
    test "installs the dripdrop schema through the wrapper migration" do
      assert %{rows: [["dripdrop"]]} =
               TestRepo.query!(
                 "SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'dripdrop'",
                 []
               )
    end

    test "installs pgmq and pgflow through PgFlow helper migrations" do
      assert %{rows: [["pgflow"], ["pgmq"]]} =
               TestRepo.query!(
                 """
                 SELECT schema_name
                 FROM information_schema.schemata
                 WHERE schema_name IN ('pgflow', 'pgmq')
                 ORDER BY schema_name
                 """,
                 []
               )
    end

    test "runs each test inside the SQL sandbox" do
      assert %{rows: [[1]]} = TestRepo.query!("SELECT 1", [])
    end

    test "installs cold outbound schema objects in the initial dripdrop schema" do
      assert %{rows: [["adapter_pool_members"], ["adapter_pools"], ["adapter_sequence_budgets"]]} =
               TestRepo.query!(
                 """
                 SELECT table_name
                 FROM information_schema.tables
                 WHERE table_schema = 'dripdrop'
                   AND table_name IN (
                     'adapter_pools',
                     'adapter_pool_members',
                     'adapter_sequence_budgets'
                   )
                 ORDER BY table_name
                 """,
                 []
               )

      assert %{rows: [[16]]} =
               TestRepo.query!(
                 """
                 SELECT count(*)
                 FROM information_schema.columns
                 WHERE table_schema = 'dripdrop'
                   AND (
                     (table_name = 'channel_adapters' AND column_name IN (
                       'health_state',
                       'health_score',
                       'resting_until',
                       'last_send_at',
                       'daily_cap',
                       'ramp_started_at',
                       'ramp_increment',
                       'ramp_floor',
                       'min_gap_seconds'
                     ))
                     OR (table_name = 'enrollments' AND column_name IN ('adapter_id', 'effective_mode'))
                     OR (table_name = 'sequence_versions' AND column_name = 'mode')
                     OR (table_name = 'steps' AND column_name = 'adapter_override_id')
                     OR (table_name = 'step_executions' AND column_name = 'out_message_id')
                     OR (table_name = 'message_events' AND column_name IN ('in_reply_to', 'references_list'))
                   )
                 """,
                 []
               )
    end
  end
end
