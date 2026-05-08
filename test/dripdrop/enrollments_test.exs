defmodule DripDrop.EnrollmentsTest do
  use DripDrop.DataCase, async: false

  alias DripDrop.{Enrollment, Event, Fixtures, StepExecution, TestRepo}

  describe "enroll/1" do
    test "creates an active enrollment and schedules the first step by sequence key" do
      %{sequence: sequence, step: step} = active_sequence()

      assert {:ok, enrollment} =
               DripDrop.enroll(%{
                 sequence_key: sequence.key,
                 subscriber: %{type: "Lead", id: "lead@example.com"},
                 data: %{name: "Ada", email: "lead@example.com"}
               })

      assert enrollment.state == "active"
      assert enrollment.subscriber_type == "Lead"
      assert enrollment.subscriber_id == "lead@example.com"
      refute is_nil(enrollment.started_at)

      assert [%StepExecution{step_id: step_id, state: "scheduled", scheduler_job_id: job_id}] =
               TestRepo.all(
                 from(execution in StepExecution,
                   where: execution.enrollment_id == ^enrollment.id
                 )
               )

      assert step_id == step.id
      assert is_binary(job_id)
    end

    test "re-enrollment while active is a no-op and does not duplicate executions" do
      %{sequence: sequence} = active_sequence()
      attrs = enrollment_attrs(sequence)

      assert {:ok, first} = DripDrop.enroll(attrs)
      assert {:ok, second} = DripDrop.enroll(attrs)

      assert second.id == first.id

      assert TestRepo.aggregate(
               from(execution in StepExecution, where: execution.enrollment_id == ^first.id),
               :count
             ) == 1
    end

    test "outbound enrollment stores adapter pin and effective mode atomically" do
      attach_telemetry([:dripdrop, :dispatch, :adapter_pinned])
      %{sequence: sequence, adapter: adapter} = active_outbound_sequence()

      assert {:ok, enrollment} = DripDrop.enroll(enrollment_attrs(sequence))
      assert enrollment.adapter_id == adapter.id
      assert enrollment.effective_mode == :outbound

      assert [%StepExecution{}] =
               TestRepo.all(
                 from(execution in StepExecution,
                   where: execution.enrollment_id == ^enrollment.id
                 )
               )

      assert_receive {:telemetry, [:dripdrop, :dispatch, :adapter_pinned], %{count: 1},
                      %{enrollment_id: enrollment_id, adapter_id: adapter_id}}

      assert enrollment_id == enrollment.id
      assert adapter_id == adapter.id
    end

    test "lifecycle enrollment leaves outbound pin columns unset" do
      %{sequence: sequence} = active_sequence()

      assert {:ok, enrollment} = DripDrop.enroll(enrollment_attrs(sequence))
      assert is_nil(enrollment.adapter_id)
      assert is_nil(enrollment.effective_mode)
    end

    test "duplicate outbound enrollment returns existing pin without re-rolling" do
      %{sequence: sequence, adapter: adapter} = active_outbound_sequence()
      attrs = enrollment_attrs(sequence)

      assert {:ok, first} = DripDrop.enroll(attrs)
      assert {:ok, second} = DripDrop.enroll(attrs)

      assert second.id == first.id
      assert second.adapter_id == adapter.id
    end

    test "outbound enrollment returns pool exhausted when no member is eligible" do
      attach_telemetry([:dripdrop, :dispatch, :pool_exhausted])

      %{sequence: sequence, pool: pool, adapter: adapter} =
        active_outbound_sequence(resting?: true)

      assert {:error,
              %{reason: :pool_exhausted, pool_id: pool_id, evicted_adapter_ids: [adapter_id]}} =
               DripDrop.enroll(enrollment_attrs(sequence))

      assert pool_id == pool.id
      assert adapter_id == adapter.id

      assert_receive {:telemetry, [:dripdrop, :dispatch, :pool_exhausted], %{count: 1},
                      %{pool_id: ^pool_id, evicted_adapter_ids: [^adapter_id]}}
    end

    test "outbound enrollment can reassign to an active resting member when configured" do
      %{sequence: sequence, adapter: adapter} =
        active_outbound_sequence(resting?: true, on_pin_unavailable: :reassign)

      assert {:ok, enrollment} = DripDrop.enroll(enrollment_attrs(sequence))

      assert enrollment.adapter_id == adapter.id
      assert enrollment.effective_mode == :outbound
      assert enrollment.metadata["pin_unavailable_reassigned"] == true
      assert enrollment.metadata["evicted_adapter_ids"] == [adapter.id]
    end

    test "re-enrollment after completion creates a new row only when allowed" do
      %{sequence: sequence} = active_sequence(%{metadata: %{"allow_reenrollment" => true}})
      attrs = enrollment_attrs(sequence)

      assert {:ok, first} = DripDrop.enroll(attrs)

      first
      |> Enrollment.transition_changeset("completed")
      |> TestRepo.update!()

      assert {:ok, second} = DripDrop.enroll(attrs)
      refute second.id == first.id
    end

    test "tenant mismatch is rejected without inserting an enrollment" do
      %{sequence: sequence} = active_sequence(%{tenant_key: "acct_a"})

      assert {:error, :tenant_mismatch} =
               DripDrop.enroll(
                 sequence_key: sequence.key,
                 tenant_key: "acct_b",
                 subscriber: %{type: "User", id: "u_123"}
               )

      assert TestRepo.aggregate(Enrollment, :count) == 0
    end
  end

  describe "state transitions" do
    test "pause cancels pending executions and resume schedules the next unsent step" do
      %{sequence: sequence, version: version} = active_sequence()
      Fixtures.step_fixture(version, %{key: "second", position: 2})

      assert {:ok, enrollment} = DripDrop.enroll(enrollment_attrs(sequence))

      assert {:ok, paused} = DripDrop.pause_enrollment(enrollment.id, enrollment.tenant_key)
      assert paused.state == "paused"

      assert TestRepo.all(
               from(execution in StepExecution,
                 where: execution.enrollment_id == ^enrollment.id,
                 select: execution.state
               )
             ) == ["cancelled"]

      assert {:ok, resumed} = DripDrop.resume_enrollment(enrollment.id, enrollment.tenant_key)
      assert resumed.state == "active"

      assert TestRepo.exists?(
               from(execution in StepExecution,
                 where: execution.enrollment_id == ^enrollment.id,
                 where: execution.state == "scheduled"
               )
             )
    end

    test "pause and resume preserve outbound adapter pin" do
      %{sequence: sequence, adapter: adapter} = active_outbound_sequence()

      assert {:ok, enrollment} = DripDrop.enroll(enrollment_attrs(sequence))
      assert {:ok, paused} = DripDrop.pause_enrollment(enrollment.id, enrollment.tenant_key)
      assert {:ok, resumed} = DripDrop.resume_enrollment(enrollment.id, enrollment.tenant_key)

      assert paused.adapter_id == adapter.id
      assert resumed.adapter_id == adapter.id
    end

    test "cancel paused enrollment sets cancelled_at and cancels pending executions" do
      %{sequence: sequence} = active_sequence()
      assert {:ok, enrollment} = DripDrop.enroll(enrollment_attrs(sequence))
      assert {:ok, paused} = DripDrop.pause_enrollment(enrollment.id, enrollment.tenant_key)

      assert {:ok, cancelled} = DripDrop.unenroll(paused.id, paused.tenant_key)
      assert cancelled.state == "cancelled"
      refute is_nil(cancelled.cancelled_at)
    end

    test "rejects completed to active transition" do
      %{sequence: sequence} = active_sequence()
      assert {:ok, enrollment} = DripDrop.enroll(enrollment_attrs(sequence))

      enrollment
      |> Enrollment.transition_changeset("completed")
      |> TestRepo.update!()

      assert {:error, :invalid_transition} =
               DripDrop.resume_enrollment(enrollment.id, enrollment.tenant_key)
    end
  end

  describe "repin_enrollment/3" do
    test "updates the adapter pin and records an audit event" do
      attach_telemetry([:dripdrop, :enrollment, :sender_reassigned])
      %{sequence: sequence, adapter: old_adapter} = active_outbound_sequence()

      new_adapter =
        Fixtures.channel_adapter_fixture(%{tenant_key: sequence.tenant_key, name: "New SMTP"})

      assert {:ok, enrollment} = DripDrop.enroll(enrollment_attrs(sequence))

      assert {:ok, repinned} =
               DripDrop.repin_enrollment(enrollment.id, new_adapter.id,
                 tenant_key: sequence.tenant_key,
                 reason: "compliance_request"
               )

      assert repinned.adapter_id == new_adapter.id

      event =
        TestRepo.get_by!(Event, enrollment_id: enrollment.id, event_key: "sender_reassigned")

      assert event.event_type == "enrollment_event"
      assert event.event_data["old_adapter_id"] == old_adapter.id
      assert event.event_data["new_adapter_id"] == new_adapter.id
      assert event.event_data["reason"] == "compliance_request"

      assert_receive {:telemetry, [:dripdrop, :enrollment, :sender_reassigned], %{count: 1},
                      %{old_adapter_id: old_adapter_id, new_adapter_id: new_adapter_id}}

      assert old_adapter_id == old_adapter.id
      assert new_adapter_id == new_adapter.id
    end
  end

  describe "track_event/3" do
    test "tracks events linked to an enrollment" do
      %{sequence: sequence} = active_sequence()
      assert {:ok, enrollment} = DripDrop.enroll(enrollment_attrs(sequence))

      assert {:ok, event} =
               DripDrop.track_event(
                 enrollment.id,
                 "viewed_pricing",
                 %{plan: "pro"},
                 enrollment.tenant_key
               )

      assert event.enrollment_id == enrollment.id
      assert event.subscriber_type == enrollment.subscriber_type
      assert event.subscriber_id == enrollment.subscriber_id
      assert event.event_data == %{"plan" => "pro"}
    end

    test "tracks events before enrollment exists" do
      assert {:ok, event} =
               DripDrop.track_event(
                 %{subscriber_type: "User", subscriber_id: "u_123"},
                 "signed_up",
                 %{}
               )

      assert is_nil(event.enrollment_id)
      assert event.subscriber_type == "User"
      assert event.subscriber_id == "u_123"
    end

    test "event-triggered steps schedule for matching subscribers" do
      %{sequence: sequence, version: version} = active_sequence()

      event_step =
        Fixtures.step_fixture(version, %{
          key: "pricing-followup",
          position: 2,
          timing: %{type: "event", trigger_event: "viewed_pricing"}
        })

      assert {:ok, enrollment} = DripDrop.enroll(enrollment_attrs(sequence))

      assert {:ok, _event} =
               DripDrop.track_event(enrollment.id, "viewed_pricing", %{}, enrollment.tenant_key)

      assert TestRepo.exists?(
               from(execution in StepExecution,
                 where: execution.enrollment_id == ^enrollment.id,
                 where: execution.step_id == ^event_step.id
               )
             )
    end

    test "recent subscriber lookup uses the composite event index" do
      # Seed enough rows that the planner clearly prefers the compound
      # `(tenant_key, subscriber_type, subscriber_id, event_key, occurred_at)`
      # index over the narrow `tenant_key`-only index.
      for i <- 1..200 do
        DripDrop.track_event(
          %{subscriber_type: "User", subscriber_id: "u_#{i}"},
          "viewed_pricing",
          %{}
        )
      end

      DripDrop.track_event(
        %{subscriber_type: "User", subscriber_id: "u_1"},
        "viewed_pricing",
        %{}
      )

      {:ok, plan} =
        TestRepo.transaction(fn ->
          TestRepo.query!("ANALYZE dripdrop.events", [])
          TestRepo.query!("SET LOCAL enable_seqscan = off", [])

          TestRepo.query!("""
          EXPLAIN SELECT *
          FROM dripdrop.events
          WHERE tenant_key IS NULL
            AND subscriber_type = 'User'
            AND subscriber_id = 'u_1'
            AND event_key = 'viewed_pricing'
          ORDER BY occurred_at DESC
          LIMIT 1
          """)
          |> Map.fetch!(:rows)
          |> List.flatten()
          |> Enum.join("\n")
        end)

      assert plan =~ "events_subscriber_lookup_idx"
    end
  end

  defp active_sequence(sequence_attrs \\ %{}) do
    sequence_attrs = Map.put_new(sequence_attrs, :tenant_key, nil)
    sequence = Fixtures.sequence_fixture(sequence_attrs)
    version = Fixtures.sequence_version_fixture(sequence, %{state: "active"})
    step = Fixtures.step_fixture(version, %{position: 1, config: %{"recipient_key" => "email"}})

    %{sequence: sequence, version: version, step: step}
  end

  defp active_outbound_sequence(opts \\ []) do
    sequence = Fixtures.sequence_fixture(%{tenant_key: "tenant-a"})

    pool =
      Fixtures.adapter_pool_fixture(%{
        tenant_key: sequence.tenant_key,
        on_pin_unavailable: Keyword.get(opts, :on_pin_unavailable, :pause)
      })

    health_attrs =
      if Keyword.get(opts, :resting?, false) do
        %{
          health_state: :resting,
          resting_until: DateTime.add(DateTime.utc_now(:second), 3600, :second)
        }
      else
        %{health_state: :active}
      end

    adapter =
      Fixtures.channel_adapter_fixture(
        Map.merge(%{tenant_key: sequence.tenant_key, name: "Outbound SMTP"}, health_attrs)
      )

    Fixtures.adapter_pool_member_fixture(pool, adapter)

    version =
      Fixtures.sequence_version_fixture(sequence, %{
        state: "active",
        mode: :outbound,
        config: %{"pool_id" => pool.id}
      })

    step = Fixtures.step_fixture(version, %{position: 1, config: %{"recipient_key" => "email"}})

    %{sequence: sequence, version: version, step: step, pool: pool, adapter: adapter}
  end

  defp enrollment_attrs(sequence) do
    %{
      sequence_key: sequence.key,
      tenant_key: sequence.tenant_key,
      subscriber: %{type: "User", id: "u_123"},
      data: %{email: "ada@example.com"}
    }
  end

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
end
