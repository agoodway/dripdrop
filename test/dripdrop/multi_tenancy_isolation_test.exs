defmodule DripDrop.MultiTenancyIsolationTest do
  @moduledoc """
  End-to-end isolation proofs (T2). These tests demonstrate that the security
  fixes from PR1 (tenant-scoped suppression indexes), PR2 (webhook event
  mis-association), and PR6 (`matching_event_steps` tenant scope) actually
  enforce isolation at the query layer, not just at the changeset layer.
  """

  use DripDrop.DataCase, async: false

  alias DripDrop.{Enrollments, Fixtures, Suppressions, TestRepo}
  alias DripDrop.Suppression
  import Ecto.Query

  setup do
    sequence_a = Fixtures.sequence_fixture(%{tenant_key: "tenant-a"})
    sequence_b = Fixtures.sequence_fixture(%{tenant_key: "tenant-b"})
    version_a = Fixtures.sequence_version_fixture(sequence_a)
    version_b = Fixtures.sequence_version_fixture(sequence_b)

    {:ok,
     sequence_a: sequence_a, sequence_b: sequence_b, version_a: version_a, version_b: version_b}
  end

  describe "suppressions" do
    test "a suppression in tenant A does not block tenant B" do
      {:ok, _suppression} =
        Suppressions.suppress(%{
          tenant_key: "tenant-a",
          channel: "email",
          recipient: "shared@example.com",
          reason: "manual"
        })

      refute Suppressions.suppressed?("email", "shared@example.com", "tenant-b")
      assert Suppressions.suppressed?("email", "shared@example.com", "tenant-a")
    end

    test "global suppressions do not collide with tenant-scoped suppressions" do
      {:ok, _global} =
        Suppressions.suppress(%{
          tenant_key: nil,
          channel: "email",
          recipient: "shared@example.com",
          reason: "manual"
        })

      {:ok, _scoped} =
        Suppressions.suppress(%{
          tenant_key: "tenant-a",
          channel: "email",
          recipient: "shared@example.com",
          reason: "bounce"
        })

      assert TestRepo.aggregate(Suppression, :count) == 2
    end
  end

  describe "matching_event_steps (PR6)" do
    test "event seeding only matches steps for the event's tenant", %{
      sequence_a: sequence_a,
      version_a: version_a,
      version_b: version_b
    } do
      step_a =
        Fixtures.step_fixture(version_a, %{
          tenant_key: "tenant-a",
          channel: "email",
          timing: %{type: "event", trigger_event: "login"}
        })

      _step_b =
        Fixtures.step_fixture(version_b, %{
          tenant_key: "tenant-b",
          channel: "email",
          timing: %{type: "event", trigger_event: "login"}
        })

      enrollment_a = Fixtures.enrollment_fixture(sequence_a, version_a)

      {:ok, _event} =
        Enrollments.track_event(enrollment_a.id, "login", %{}, enrollment_a.tenant_key)

      step_executions =
        from(execution in DripDrop.StepExecution,
          where: execution.step_id == ^step_a.id
        )
        |> TestRepo.all()

      assert Enum.any?(step_executions, &(&1.enrollment_id == enrollment_a.id))

      cross_tenant =
        from(execution in DripDrop.StepExecution,
          where:
            execution.tenant_key == "tenant-b" and execution.enrollment_id == ^enrollment_a.id
        )
        |> TestRepo.all()

      assert cross_tenant == []
    end
  end

  describe "list_active_enrollments tenant scope" do
    test "returns only enrollments for the requested tenant", %{
      sequence_a: sequence_a,
      version_a: version_a,
      sequence_b: sequence_b,
      version_b: version_b
    } do
      _enrollment_a = Fixtures.enrollment_fixture(sequence_a, version_a)
      _enrollment_b = Fixtures.enrollment_fixture(sequence_b, version_b)

      results = Enrollments.list_active_enrollments(%{tenant_key: "tenant-a"})

      assert length(results) == 1
      assert hd(results).tenant_key == "tenant-a"
    end
  end

  describe "global queries fail without an explicit tenant" do
    test "list_active_enrollments raises when scope is missing" do
      assert_raise ArgumentError, ~r/tenant_key/, fn ->
        Enrollments.list_active_enrollments(%{})
      end
    end
  end

  describe "authoring rejects tenant_key spoofing" do
    test "create_step ignores caller-supplied tenant_key and uses parent version's", %{
      version_a: version_a
    } do
      assert {:ok, step} =
               DripDrop.SequenceAuthoring.create_step(version_a.id, %{
                 tenant_key: "victim",
                 name: "Spoof",
                 key: "spoof",
                 channel: "email",
                 position: 1,
                 timing: %{type: "immediate"}
               })

      assert step.tenant_key == "tenant-a"
      refute step.tenant_key == "victim"
    end

    test "create_step_transition uses parent version's tenant_key", %{version_a: version_a} do
      from_step = Fixtures.step_fixture(version_a, %{key: "from", position: 1})
      to_step = Fixtures.step_fixture(version_a, %{key: "to", position: 2})

      assert {:ok, transition} =
               DripDrop.SequenceAuthoring.create_step_transition(version_a.id, %{
                 tenant_key: "victim",
                 from_step_id: from_step.id,
                 to_step_id: to_step.id
               })

      assert transition.tenant_key == "tenant-a"
    end

    test "create_condition derives tenant_key from the parent step", %{version_a: version_a} do
      step = Fixtures.step_fixture(version_a, %{key: "with-cond", position: 1})

      assert {:ok, condition} =
               DripDrop.SequenceAuthoring.create_condition(step.id, %{
                 tenant_key: "victim",
                 condition_type: "enrollment_data",
                 operator: "==",
                 field_path: "plan",
                 expected_value: "pro"
               })

      assert condition.tenant_key == "tenant-a"
    end

    test "create_sequence_version uses the parent sequence's tenant_key", %{
      sequence_a: sequence_a
    } do
      assert {:ok, version} =
               DripDrop.SequenceAuthoring.create_sequence_version(sequence_a.id, %{
                 tenant_key: "victim",
                 version: 99
               })

      assert version.tenant_key == "tenant-a"
    end
  end

  describe "lifecycle ops require correct tenant scope" do
    test "track_event raises when called with wrong tenant for a tenant-A enrollment", %{
      sequence_a: sequence_a,
      version_a: version_a
    } do
      enrollment_a = Fixtures.enrollment_fixture(sequence_a, version_a)

      assert_raise Ecto.NoResultsError, fn ->
        Enrollments.track_event(enrollment_a.id, "login", %{}, "tenant-b")
      end
    end

    test "pause_enrollment raises when called with wrong tenant", %{
      sequence_a: sequence_a,
      version_a: version_a
    } do
      enrollment_a = Fixtures.enrollment_fixture(sequence_a, version_a)

      assert_raise Ecto.NoResultsError, fn ->
        Enrollments.pause_enrollment(enrollment_a.id, "tenant-b")
      end
    end

    test "unenroll raises when called with wrong tenant", %{
      sequence_a: sequence_a,
      version_a: version_a
    } do
      enrollment_a = Fixtures.enrollment_fixture(sequence_a, version_a)

      assert_raise Ecto.NoResultsError, fn ->
        Enrollments.unenroll(enrollment_a.id, "tenant-b")
      end
    end
  end
end
