defmodule DripDrop.Integration.ChaosTest do
  use DripDrop.IntegrationCase

  @moduletag :integration

  alias Ecto.Adapters.SQL

  alias DripDrop.{
    Fixtures,
    MessageEvent,
    StepExecution,
    TestRepo
  }

  alias DripDrop.TestSupport.Channels.CrashEmail
  alias DripDrop.TestSupport.PgflowHarness

  setup_all do
    previous_scheduler = Application.get_env(:dripdrop, :scheduler)
    previous_stale_after = Application.get_env(:dripdrop, :dispatch_stale_after_seconds)
    registry_key = {DripDrop.Channels, :providers}
    previous_providers = :persistent_term.get(registry_key, %{})

    Application.put_env(:dripdrop, :scheduler, DripDrop.Schedulers.Pgflow)
    Application.put_env(:dripdrop, :dispatch_stale_after_seconds, 2)
    :ok = DripDrop.Channels.register(:email, :crash_email, CrashEmail)

    on_exit(fn ->
      Application.put_env(:dripdrop, :scheduler, previous_scheduler)
      Application.put_env(:dripdrop, :dispatch_stale_after_seconds, previous_stale_after)
      :persistent_term.put(registry_key, previous_providers)
    end)

    :ok
  end

  test "worker crash after provider success retries stale sending execution once" do
    agent_name = :"chaos_calls_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: agent_name,
      start: {Agent, :start_link, [fn -> 0 end, [name: agent_name]]}
    })

    configure_pgflow_retry!(max_attempts: 2, base_delay: 3, timeout: 2)

    start_supervised!(
      PgflowHarness.child_spec(
        recovery_interval: 250,
        stale_threshold: 2,
        min_poll_interval: 100,
        max_poll_interval: 100,
        notify_fallback_interval: 100
      )
    )

    %{sequence: sequence, step: step, enroll_attrs: enroll_attrs} =
      crash_email_scenario(agent_name)

    assert {:ok, enrollment} = DripDrop.enroll(enroll_attrs)

    first_idempotency_key =
      eventually(fn ->
        execution = step_execution!(enrollment.id, step.id)
        assert execution.state == "sending"
        assert Agent.get(agent_name, & &1) == 1
        execution.idempotency_key
      end)

    sent_execution =
      eventually(
        fn ->
          execution = step_execution!(enrollment.id, step.id)
          assert execution.state == "sent"
          assert execution.provider_message_id == "msg-2"
          execution
        end,
        timeout: 8_000
      )

    assert Agent.get(agent_name, & &1) == 2
    assert sent_execution.idempotency_key == first_idempotency_key
    assert sent_execution.enrollment_id == enrollment.id
    assert sent_execution.step_id == step.id

    assert TestRepo.aggregate(
             from(execution in StepExecution,
               where: execution.enrollment_id == ^enrollment.id and execution.step_id == ^step.id
             ),
             :count
           ) == 1

    assert TestRepo.aggregate(
             from(event in MessageEvent,
               where: event.step_execution_id == ^sent_execution.id and event.event_type == "sent"
             ),
             :count
           ) == 1

    assert TestRepo.get!(DripDrop.Enrollment, enrollment.id).sequence_id == sequence.id
  end

  defp crash_email_scenario(agent_name) do
    adapter =
      Fixtures.channel_adapter_fixture(%{
        tenant_key: "tenant-a",
        name: "Crash email",
        channel: "email",
        provider: "crash_email",
        credentials: %{},
        config: %{
          "agent_name" => Atom.to_string(agent_name),
          "crash_mode" => "after_success"
        },
        is_default: true
      })

    sequence = Fixtures.sequence_fixture(%{tenant_key: "tenant-a", key: unique_key("chaos")})
    version = Fixtures.sequence_version_fixture(sequence, %{state: "draft"})

    step =
      Fixtures.step_fixture(version, %{
        key: "crash",
        position: 1,
        channel_adapter_id: adapter.id,
        template_content: %{
          "from" => "team@example.com",
          "subject" => "Crash test",
          "text" => "Hello"
        }
      })

    {:ok, _version} = DripDrop.activate_sequence_version(version.id)

    %{
      adapter: adapter,
      sequence: sequence,
      step: step,
      enroll_attrs: %{
        sequence_id: sequence.id,
        subscriber_type: "user",
        subscriber_id: unique_key("subscriber"),
        tenant_key: "tenant-a",
        data: %{"email" => "sam@example.com", "first_name" => "Sam"}
      }
    }
  end

  defp configure_pgflow_retry!(opts) do
    max_attempts = Keyword.fetch!(opts, :max_attempts)
    base_delay = Keyword.fetch!(opts, :base_delay)
    timeout = Keyword.fetch!(opts, :timeout)

    SQL.query!(
      TestRepo,
      """
      UPDATE pgflow.flows
      SET opt_max_attempts = $1, opt_base_delay = $2, opt_timeout = $3
      WHERE flow_slug = 'dispatch_step'
      """,
      [max_attempts, base_delay, timeout]
    )

    SQL.query!(
      TestRepo,
      """
      UPDATE pgflow.steps
      SET opt_max_attempts = $1, opt_base_delay = $2, opt_timeout = $3
      WHERE flow_slug = 'dispatch_step' AND step_slug = 'dispatch'
      """,
      [max_attempts, base_delay, timeout]
    )
  end

  defp step_execution!(enrollment_id, step_id) do
    TestRepo.one!(
      from(execution in StepExecution,
        where: execution.enrollment_id == ^enrollment_id and execution.step_id == ^step_id
      )
    )
  end

  defp unique_key(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
