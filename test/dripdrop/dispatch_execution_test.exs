defmodule DripDrop.DispatchExecutionTest do
  use DripDrop.DataCase, async: false

  alias DripDrop.Channel
  alias DripDrop.Channels
  alias DripDrop.Channels.Provider

  alias DripDrop.{
    Dispatch,
    Enrollment,
    Fixtures,
    MessageEvent,
    StepExecution,
    Suppression,
    TestRepo
  }

  alias DripDrop.Jobs.DispatchStep

  defmodule RecorderProvider do
    @moduledoc """
    In-process provider used by dispatch tests to avoid external network calls.
    """

    use Provider

    @impl Channel
    def deliver(step, _enrollment, adapter) do
      payload = get_in(step.config || %{}, ["payload"]) || %{}
      record_delivery(adapter.config, payload)

      case adapter.config["result"] do
        "temporary_error" ->
          {:error, %{kind: :temporary, reason: :rate_limited}}

        "hard_bounce" ->
          {:error, %{kind: :permanent, reason: {:hard_bounce, "550 5.1.1"}}}

        _success ->
          {:ok,
           %{
             provider_message_id: "msg_#{payload[:idempotency_key]}",
             response: %{status: "accepted"}
           }}
      end
    end

    defp record_delivery(config, payload) do
      recorder = config["recorder"] || config[:recorder]

      if is_binary(recorder),
        do: Agent.update({:global, recorder}, &record_payload(&1, payload, config))
    end

    defp record_payload(deliveries, payload, %{"idempotent" => true}) do
      if Enum.any?(deliveries, &same_key?(&1, payload)),
        do: deliveries,
        else: [payload | deliveries]
    end

    defp record_payload(deliveries, payload, _config), do: [payload | deliveries]

    defp same_key?(left, right), do: left[:idempotency_key] == right[:idempotency_key]
  end

  defmodule SchedulerRecorder do
    @moduledoc """
    Scheduler implementation that records reschedules for retry assertions.
    """

    alias DripDrop.Scheduler

    @behaviour Scheduler

    @impl Scheduler
    def schedule(execution, scheduled_for) do
      send(test_pid(), {:scheduled_retry, execution.id, scheduled_for, execution.state})
      {:ok, {:scheduler_recorder, execution.id}}
    end

    @impl Scheduler
    def cancel(_job_id), do: :ok

    defp test_pid do
      :persistent_term.get({__MODULE__, :test_pid})
    end
  end

  setup do
    recorder = "dispatch-recorder-#{System.unique_integer([:positive])}"
    {:ok, _agent} = Agent.start_link(fn -> [] end, name: {:global, recorder})
    register_test_provider()

    on_exit(fn ->
      case :global.whereis_name(recorder) do
        :undefined -> :ok
        pid -> Agent.stop(pid)
      end
    end)

    {:ok, recorder: recorder}
  end

  describe "dispatch worker" do
    test "only one competing worker sends a scheduled execution", %{recorder: recorder} do
      %{execution: execution} = dispatch_context(recorder)

      results =
        1..2
        |> Task.async_stream(fn _index ->
          DispatchStep.perform(%{step_execution_id: execution.id})
        end)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.sort(results) == [:ok, :ok]
      assert TestRepo.get!(StepExecution, execution.id).state == "sent"
      assert delivery_count(recorder) == 1
    end

    test "temporary provider errors keep the idempotency key stable while retrying", %{
      recorder: recorder
    } do
      %{execution: execution} =
        dispatch_context(recorder,
          adapter_config: %{"result" => "temporary_error"},
          step_config: %{"max_retries" => 2, "quiet_hours" => false}
        )

      assert :ok = DispatchStep.perform(%{step_execution_id: execution.id})

      reloaded = TestRepo.get!(StepExecution, execution.id)
      assert reloaded.state == "scheduled"
      assert reloaded.retry_count == 1
      assert reloaded.idempotency_key == execution.idempotency_key
      assert [delivery] = deliveries(recorder)
      assert delivery[:idempotency_key] == execution.idempotency_key
    end

    test "temporary retries pass through the configured scheduler", %{recorder: recorder} do
      previous_scheduler = Application.get_env(:dripdrop, :scheduler)
      :persistent_term.put({SchedulerRecorder, :test_pid}, self())
      Application.put_env(:dripdrop, :scheduler, SchedulerRecorder)

      on_exit(fn ->
        Application.put_env(:dripdrop, :scheduler, previous_scheduler)
        :persistent_term.erase({SchedulerRecorder, :test_pid})
      end)

      %{execution: execution} =
        dispatch_context(recorder,
          adapter_config: %{"result" => "temporary_error"},
          step_config: %{"max_retries" => 2, "quiet_hours" => false}
        )

      assert :ok = DispatchStep.perform(%{step_execution_id: execution.id})

      assert_receive {:scheduled_retry, execution_id, scheduled_for, "scheduled"}
      assert execution_id == execution.id
      assert %DateTime{} = scheduled_for
    end

    test "stale sending recovery reuses the same idempotency key without duplicate provider output",
         %{recorder: recorder} do
      %{execution: execution} =
        dispatch_context(recorder,
          adapter_config: %{"idempotent" => true},
          execution_attrs: %{
            state: "scheduled",
            claimed_at: DateTime.utc_now(:second) |> DateTime.add(-1_000, :second)
          }
        )

      Agent.update({:global, recorder}, fn _deliveries ->
        [%{idempotency_key: execution.idempotency_key}]
      end)

      stale =
        execution
        |> StepExecution.changeset(%{state: "claiming"})
        |> TestRepo.update!()
        |> StepExecution.changeset(%{state: "sending"})
        |> TestRepo.update!()

      assert stale.idempotency_key == execution.idempotency_key
      assert :ok = DispatchStep.perform(%{step_execution_id: execution.id})

      reloaded = TestRepo.get!(StepExecution, execution.id)
      assert reloaded.state == "sent"
      assert reloaded.idempotency_key == execution.idempotency_key
      assert delivery_count(recorder) == 1
    end

    test "exhausted retry budget cancels the enrollment by default", %{recorder: recorder} do
      %{enrollment: enrollment, execution: execution} =
        dispatch_context(recorder,
          adapter_config: %{"result" => "temporary_error"},
          execution_attrs: %{retry_count: 1},
          step_config: %{"max_retries" => 2, "quiet_hours" => false}
        )

      assert {:error, %{kind: :temporary, reason: :rate_limited}} =
               DispatchStep.perform(%{step_execution_id: execution.id})

      assert TestRepo.get!(StepExecution, execution.id).state == "failed"
      assert TestRepo.get!(StepExecution, execution.id).retry_count == 2
      assert TestRepo.get!(Enrollment, enrollment.id).state == "cancelled"
    end

    test "exhausted retry budget can continue to the next step", %{recorder: recorder} do
      %{enrollment: enrollment, execution: execution, version: version} =
        dispatch_context(recorder,
          adapter_config: %{"result" => "temporary_error"},
          execution_attrs: %{retry_count: 1},
          step_config: %{
            "max_retries" => 2,
            "on_max_retry" => "continue",
            "quiet_hours" => false
          }
        )

      next_step = Fixtures.step_fixture(version, %{key: "next", position: 2})

      assert {:error, %{kind: :temporary, reason: :rate_limited}} =
               DispatchStep.perform(%{step_execution_id: execution.id})

      assert TestRepo.exists?(
               from(step_execution in StepExecution,
                 where: step_execution.enrollment_id == ^enrollment.id,
                 where: step_execution.step_id == ^next_step.id,
                 where: step_execution.state == "scheduled"
               )
             )
    end

    test "permanent hard bounces suppress the normalized recipient", %{recorder: recorder} do
      %{execution: execution} =
        dispatch_context(recorder,
          adapter_config: %{"result" => "hard_bounce"},
          enrollment_attrs: %{data: %{"email" => "Ada@Example.COM"}}
        )

      assert {:error, %{kind: :permanent, reason: {:hard_bounce, "550 5.1.1"}}} =
               DispatchStep.perform(%{step_execution_id: execution.id})

      assert TestRepo.get!(StepExecution, execution.id).state == "failed"

      assert TestRepo.exists?(
               from(suppression in Suppression,
                 where: suppression.channel == "email",
                 where: suppression.recipient_normalized == "ada@example.com",
                 where: suppression.reason == "bounce"
               )
             )
    end

    test "send phase telemetry wraps the provider call", %{recorder: recorder} do
      attach_telemetry([:dripdrop, :dispatch, :phase, :start])
      attach_telemetry([:dripdrop, :dispatch, :phase, :stop])

      %{execution: execution} = dispatch_context(recorder)

      assert :ok = DispatchStep.perform(%{step_execution_id: execution.id})

      assert_receive {:telemetry, [:dripdrop, :dispatch, :phase, :start], _measurements,
                      %{phase: :send, step_execution_id: step_execution_id}}

      assert_receive {:telemetry, [:dripdrop, :dispatch, :phase, :stop], %{duration: duration},
                      %{phase: :send}}

      assert step_execution_id == execution.id
      assert is_integer(duration)
    end

    test "channel concurrency allows the current worker and defers behind another in-flight row",
         %{
           recorder: recorder
         } do
      previous_concurrency = Application.get_env(:dripdrop, :dispatch_concurrency)

      Application.put_env(:dripdrop, :dispatch_concurrency,
        channel: %{email: 1},
        adapter: %{},
        defer_seconds: 30
      )

      on_exit(fn ->
        Application.put_env(:dripdrop, :dispatch_concurrency, previous_concurrency)
      end)

      %{execution: first_execution} = dispatch_context(recorder)
      assert :ok = DispatchStep.perform(%{step_execution_id: first_execution.id})
      assert TestRepo.get!(StepExecution, first_execution.id).state == "sent"

      %{execution: second_execution, enrollment: enrollment, step: step} =
        dispatch_context(recorder)

      _in_flight =
        enrollment
        |> Fixtures.step_execution_fixture(step)
        |> StepExecution.changeset(%{state: "claiming"})
        |> TestRepo.update!()

      assert :ok = DispatchStep.perform(%{step_execution_id: second_execution.id})

      reloaded = TestRepo.get!(StepExecution, second_execution.id)
      assert reloaded.state == "scheduled"
      assert DateTime.compare(reloaded.scheduled_for, second_execution.scheduled_for) == :gt
    end

    test "admin replay bumps attempt window and creates a fresh idempotency key", %{
      recorder: recorder
    } do
      %{execution: execution} = dispatch_context(recorder)

      failed =
        execution
        |> StepExecution.changeset(%{state: "claiming"})
        |> TestRepo.update!()
        |> StepExecution.changeset(%{state: "failed", retry_count: 2})
        |> TestRepo.update!()

      assert {:ok, replayed} = Dispatch.replay(failed.id)
      assert replayed.state == "scheduled"
      assert replayed.attempt_window == failed.attempt_window + 1
      refute replayed.idempotency_key == failed.idempotency_key
      assert replayed.scheduler_job_id =~ ":test_job"
    end

    test "suppressed executions skip and still advance to the next step", %{recorder: recorder} do
      %{enrollment: enrollment, execution: execution, version: version} =
        dispatch_context(recorder, enrollment_attrs: %{data: %{"email" => "ada@example.com"}})

      next_step = Fixtures.step_fixture(version, %{key: "next", position: 2})

      assert {:ok, _suppression} =
               DripDrop.Suppressions.suppress(%{
                 tenant_key: enrollment.tenant_key,
                 channel: "email",
                 recipient: "ADA@example.com",
                 reason: "complaint",
                 source: "test"
               })

      assert :ok = DispatchStep.perform(%{step_execution_id: execution.id})

      assert TestRepo.get!(StepExecution, execution.id).state == "skipped"
      assert delivery_count(recorder) == 0

      assert TestRepo.exists?(
               from(step_execution in StepExecution,
                 where: step_execution.enrollment_id == ^enrollment.id,
                 where: step_execution.step_id == ^next_step.id,
                 where: step_execution.state == "scheduled"
               )
             )

      assert TestRepo.exists?(
               from(message_event in MessageEvent,
                 where: message_event.step_execution_id == ^execution.id,
                 where: message_event.event_type == "skipped"
               )
             )
    end
  end

  defp dispatch_context(recorder, opts \\ []) do
    sequence = Fixtures.sequence_fixture()
    version = Fixtures.sequence_version_fixture(sequence, %{state: "active"})

    step =
      Fixtures.step_fixture(version, %{
        key: "current",
        position: 1,
        config: Keyword.get(opts, :step_config, %{"quiet_hours" => false}),
        template_content: %{"subject" => "Welcome", "text" => "Hello {{ subscriber_id }}"}
      })

    Fixtures.channel_adapter_fixture(%{
      tenant_key: sequence.tenant_key,
      provider: "dispatch_recorder",
      is_default: true,
      config: Map.put(Keyword.get(opts, :adapter_config, %{}), "recorder", recorder)
    })

    enrollment =
      Fixtures.enrollment_fixture(
        sequence,
        version,
        Keyword.get(opts, :enrollment_attrs, %{data: %{"email" => "ada@example.com"}})
      )

    execution =
      Fixtures.step_execution_fixture(
        enrollment,
        step,
        Map.merge(
          %{
            recipient: enrollment.data["email"],
            idempotency_key: "idem-#{System.unique_integer([:positive])}"
          },
          Keyword.get(opts, :execution_attrs, %{})
        )
      )

    %{
      sequence: sequence,
      version: version,
      step: step,
      enrollment: enrollment,
      execution: execution
    }
  end

  defp deliveries(recorder), do: Agent.get({:global, recorder}, & &1)
  defp delivery_count(recorder), do: recorder |> deliveries() |> length()

  defp attach_telemetry(event) do
    parent = self()
    handler_id = {__MODULE__, event, System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      event,
      fn event, measurements, metadata, _config ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp register_test_provider do
    registry_key = {Channels, :providers}
    previous_providers = :persistent_term.get(registry_key, %{})

    providers =
      previous_providers
      |> Map.put_new(:email, %{})
      |> put_in([:email, :dispatch_recorder], RecorderProvider)

    :persistent_term.put(registry_key, providers)
    on_exit(fn -> :persistent_term.put(registry_key, previous_providers) end)
  end
end
