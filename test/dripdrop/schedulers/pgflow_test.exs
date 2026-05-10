defmodule DripDrop.Schedulers.PgflowTest do
  @moduledoc """
  Tests for the PgFlow scheduler adapter.
  """

  use DripDrop.DataCase, async: false

  alias DripDrop.Schedulers.Pgflow
  alias Ecto.Adapters.SQL

  setup do
    :persistent_term.put({PgFlow, :repo}, TestRepo)

    on_exit(fn ->
      :persistent_term.erase({PgFlow, :repo})
    end)
  end

  describe "schedule/2" do
    test "sets pgmq visibility to the requested future time" do
      scheduled_for = DripDrop.Clock.seconds_from_now(18)

      assert {:ok, run_id} = Pgflow.schedule(%{id: Ecto.UUID.generate()}, scheduled_for)

      {:ok, run_id_binary} = Ecto.UUID.dump(run_id)

      assert %{rows: [[%DateTime{} = visible_at]]} =
               SQL.query!(
                 TestRepo,
                 """
                 SELECT queue.vt
                 FROM pgflow.step_tasks AS task
                 JOIN pgmq.q_dispatch_step AS queue ON queue.msg_id = task.message_id
                 WHERE task.run_id = $1::uuid
                 """,
                 [run_id_binary]
               )

      assert DateTime.diff(visible_at, DripDrop.Clock.now(), :second) in 15..20
    end
  end

  describe "cancel/1" do
    test "returns :ok for nil job_id" do
      assert Pgflow.cancel(nil) == :ok
    end

    test "emits :cancel_unsupported telemetry when PgFlow.cancel/1 is not exported" do
      # The shipped PgFlow exposes `enqueue/2` but no `cancel/1`. The adapter
      # must degrade gracefully — return :ok and surface the unsupported state
      # via telemetry so operators can spot stale jobs after reschedule.
      refute function_exported?(PgFlow, :cancel, 1),
             "test assumes PgFlow.cancel/1 is not exported; if upstream added it, this test must be updated to cover the delegation path."

      handler_id = make_ref()
      parent = self()

      :telemetry.attach(
        handler_id,
        [:dripdrop, :scheduler, :pgflow, :cancel_unsupported],
        fn _event, measurements, metadata, _ ->
          send(parent, {:telemetry, measurements, metadata})
        end,
        nil
      )

      try do
        assert Pgflow.cancel("scheduler-job-123") == :ok

        assert_receive {:telemetry, %{count: 1}, %{job_id: "scheduler-job-123"}}, 100
      after
        :telemetry.detach(handler_id)
      end
    end
  end
end
