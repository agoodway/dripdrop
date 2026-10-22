defmodule DripDrop.TenantsTest do
  use DripDrop.DataCase, async: false

  import Ecto.Query

  alias DripDrop.{
    AdapterPool,
    AdapterPoolMember,
    AdapterSequenceBudget,
    ChannelAdapter,
    Condition,
    Enrollment,
    Event,
    Fixtures,
    HttpHook,
    MessageEvent,
    Sequence,
    SequenceVersion,
    ShortLink,
    Step,
    StepExecution,
    StepTransition,
    Suppression,
    Suppressions,
    TestRepo
  }

  @tenant_schemas [
    AdapterPool,
    AdapterPoolMember,
    AdapterSequenceBudget,
    ChannelAdapter,
    Condition,
    Enrollment,
    Event,
    HttpHook,
    MessageEvent,
    Sequence,
    SequenceVersion,
    ShortLink,
    Step,
    StepExecution,
    StepTransition,
    Suppression
  ]

  describe "delete_tenant/1" do
    test "deletes every row the tenant owns in every DripDrop table" do
      seed_tenant("tenant-a")

      assert Enum.all?(@tenant_schemas, &(tenant_count(&1, "tenant-a") > 0))

      assert {:ok, deleted} = DripDrop.delete_tenant("tenant-a")

      assert Enum.all?(@tenant_schemas, &(tenant_count(&1, "tenant-a") == 0))
      assert deleted.message_events == 1
      assert deleted.sequences == 1
      assert deleted.suppressions == 1
    end

    test "leaves other tenants and global rows untouched" do
      seed_tenant("tenant-a")
      seed_tenant("tenant-b")
      global_adapter = Fixtures.channel_adapter_fixture(%{tenant_key: nil, name: "Global"})
      global_sequence = Fixtures.sequence_fixture(%{tenant_key: nil})

      {:ok, global_suppression} =
        Suppressions.suppress(%{
          tenant_key: nil,
          channel: "email",
          recipient: "global@example.com",
          reason: "manual"
        })

      before = Map.new(@tenant_schemas, &{&1, tenant_count(&1, "tenant-b")})

      assert {:ok, _deleted} = DripDrop.delete_tenant("tenant-a")

      assert Map.new(@tenant_schemas, &{&1, tenant_count(&1, "tenant-b")}) == before
      assert TestRepo.get(ChannelAdapter, global_adapter.id)
      assert TestRepo.get(Sequence, global_sequence.id)
      assert TestRepo.get(Suppression, global_suppression.id)
    end

    test "deletes nothing when another tenant references the tenant's rows" do
      a = seed_tenant("tenant-a")
      b = seed_tenant("tenant-b")

      # A tenant-b event pointing at a tenant-a execution would be orphaned by
      # the delete's SET NULL, so the delete refuses instead.
      b.message_event
      |> Ecto.Changeset.change(step_execution_id: a.step_execution.id)
      |> TestRepo.update!()

      before = Map.new(@tenant_schemas, &{&1, tenant_count(&1, "tenant-a")})

      assert {:error, {:cross_tenant_references, references}} =
               DripDrop.delete_tenant("tenant-a")

      assert %{table: "message_events", column: :step_execution_id, count: 1} in references
      assert Map.new(@tenant_schemas, &{&1, tenant_count(&1, "tenant-a")}) == before
    end

    test "is a no-op for a tenant with no rows" do
      assert {:ok, deleted} = DripDrop.delete_tenant("tenant-none")
      assert Enum.all?(deleted, fn {_table, count} -> count == 0 end)
    end

    test "requires an explicit, non-blank tenant key" do
      assert_raise ArgumentError, ~r/explicit :tenant_key/, fn ->
        DripDrop.delete_tenant(nil)
      end

      assert_raise ArgumentError, ~r/explicit :tenant_key/, fn ->
        DripDrop.delete_tenant("")
      end
    end
  end

  # Seeds one row in every tenant-keyed table for `tenant_key`.
  defp seed_tenant(tenant_key) do
    adapter = Fixtures.channel_adapter_fixture(%{tenant_key: tenant_key})
    pool = Fixtures.adapter_pool_fixture(%{tenant_key: tenant_key})
    Fixtures.adapter_pool_member_fixture(pool, adapter, %{tenant_key: tenant_key})

    sequence = Fixtures.sequence_fixture(%{tenant_key: tenant_key})
    version = Fixtures.sequence_version_fixture(sequence)
    Fixtures.adapter_sequence_budget_fixture(adapter, version, %{tenant_key: tenant_key})
    step = Fixtures.step_fixture(version, %{channel_adapter_id: adapter.id})
    next_step = Fixtures.step_fixture(version, %{position: 2})
    hook = Fixtures.http_hook_fixture(sequence.id, %{tenant_key: tenant_key})

    transition =
      %StepTransition{}
      |> StepTransition.changeset(%{
        sequence_version_id: version.id,
        tenant_key: tenant_key,
        from_step_id: step.id,
        to_step_id: next_step.id
      })
      |> TestRepo.insert!()

    %Condition{}
    |> Condition.changeset(%{
      tenant_key: tenant_key,
      transition_id: transition.id,
      condition_type: "enrollment_data",
      field_path: "plan",
      expected_value: "pro"
    })
    |> TestRepo.insert!()

    enrollment = Fixtures.enrollment_fixture(sequence, version, %{adapter_id: adapter.id})
    step_execution = Fixtures.step_execution_fixture(enrollment, step)

    %Event{}
    |> Event.changeset(%{
      tenant_key: tenant_key,
      enrollment_id: enrollment.id,
      event_key: "opened"
    })
    |> TestRepo.insert!()

    message_event =
      Fixtures.message_event_fixture(%{
        tenant_key: tenant_key,
        step_execution_id: step_execution.id,
        adapter_id: adapter.id
      })

    %ShortLink{}
    |> ShortLink.changeset(%{
      tenant_key: tenant_key,
      step_execution_id: step_execution.id,
      provider: "test",
      original_url: "https://example.com",
      destination_url: "https://example.com",
      idempotency_key: "#{tenant_key}-link"
    })
    |> TestRepo.insert!()

    {:ok, _suppression} =
      Suppressions.suppress(%{
        tenant_key: tenant_key,
        channel: "email",
        recipient: "#{tenant_key}@example.com",
        reason: "manual"
      })

    %{step_execution: step_execution, message_event: message_event, http_hook: hook}
  end

  defp tenant_count(schema, tenant_key) do
    schema
    |> where([row], row.tenant_key == ^tenant_key)
    |> TestRepo.aggregate(:count)
  end
end
