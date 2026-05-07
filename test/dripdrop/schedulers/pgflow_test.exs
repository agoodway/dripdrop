defmodule DripDrop.Schedulers.PgflowTest do
  @moduledoc """
  Unit tests for the PgFlow scheduler adapter focused on the cancel-best-effort
  contract (Phase 4 Pgflow.cancel implementation). The schedule/2 path enqueues
  real PgFlow jobs and is exercised through the integration tests in
  `dispatch_execution_test.exs`; we don't re-test the queue interaction here.
  """

  use ExUnit.Case, async: false

  alias DripDrop.Schedulers.Pgflow

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
