defmodule DripDrop.SequenceAuthoringTest do
  use DripDrop.DataCase, async: false

  alias DripDrop.Channel
  alias DripDrop.Channels
  alias DripDrop.Channels.Provider
  alias DripDrop.{Condition, DBHelpers, Enrollment, SequenceVersion, StepExecution, TestRepo}
  alias DripDrop.Fixtures
  alias DripDrop.Jobs.DispatchStep

  defmodule Hooks do
    @moduledoc """
    Test hook module used by sequence-authoring branch assertions.
    """

    @spec handle_hook(atom(), map(), map()) :: {:ok, boolean()}
    def handle_hook(:setup_completed, _enrollment, _context), do: {:ok, true}
    def handle_hook(:setup_incomplete, _enrollment, _context), do: {:ok, false}
  end

  defmodule AuthoringTestProvider do
    @moduledoc """
    Test channel provider that accepts sends without external network calls.
    """

    use Provider

    @impl Channel
    def deliver(_step, _enrollment, _adapter) do
      {:ok, %{provider_message_id: Ecto.UUID.generate(), response: %{status: "accepted"}}}
    end
  end

  setup do
    register_test_provider()
    :ok
  end

  describe "sequences" do
    test "creates a sequence in single-tenant mode and rejects duplicate global keys" do
      attrs = %{name: "Onboarding", key: "saas_onboarding", hook_module: "#{Hooks}"}

      assert {:ok, sequence} = DripDrop.create_sequence(attrs)
      assert is_nil(sequence.tenant_key)

      assert {:error, changeset} = DripDrop.create_sequence(attrs)
      assert %{key: [_message]} = errors_on(changeset)
    end

    test "allows the same key in different tenants and rejects duplicates in one tenant" do
      attrs = %{name: "Onboarding", key: "onboarding"}

      assert {:ok, _sequence} = DripDrop.create_sequence(Map.put(attrs, :tenant_key, "acct_a"))
      assert {:ok, _sequence} = DripDrop.create_sequence(Map.put(attrs, :tenant_key, "acct_b"))

      assert {:error, changeset} = DripDrop.create_sequence(Map.put(attrs, :tenant_key, "acct_a"))
      assert %{key: [_message]} = errors_on(changeset)
    end

    test "allows a global key and tenant-scoped key to coexist while each scope stays unique" do
      attrs = %{name: "Onboarding", key: "shared_onboarding"}

      assert {:ok, global} = DripDrop.create_sequence(attrs)
      assert {:ok, tenant} = DripDrop.create_sequence(Map.put(attrs, :tenant_key, "acct_a"))

      assert is_nil(global.tenant_key)
      assert tenant.tenant_key == "acct_a"

      assert {:error, global_changeset} = DripDrop.create_sequence(attrs)
      assert %{key: [_message]} = errors_on(global_changeset)

      assert {:error, tenant_changeset} =
               DripDrop.create_sequence(Map.put(attrs, :tenant_key, "acct_a"))

      assert %{key: [_message]} = errors_on(tenant_changeset)
    end
  end

  describe "sequence versions" do
    test "creates draft versions by default" do
      sequence = Fixtures.sequence_fixture()

      assert {:ok, version} = DripDrop.create_sequence_version(sequence.id, %{version: 2})
      assert version.state == "draft"
      assert is_nil(version.published_at)
    end

    test "activation archives the previous active version atomically" do
      sequence = Fixtures.sequence_fixture()
      first = Fixtures.sequence_version_fixture(sequence, %{version: 1, state: "active"})
      second = Fixtures.sequence_version_fixture(sequence, %{version: 2})

      assert {:ok, activated} = DripDrop.activate_sequence_version(second.id)
      assert activated.state == "active"
      refute is_nil(activated.published_at)

      assert TestRepo.get!(SequenceVersion, first.id).state == "archived"
    end

    test "database rejects two active versions for one sequence" do
      sequence = Fixtures.sequence_fixture()
      Fixtures.sequence_version_fixture(sequence, %{version: 1, state: "active"})

      attrs = %{
        sequence_id: sequence.id,
        tenant_key: sequence.tenant_key,
        version: 2,
        state: "active"
      }

      assert {:error, changeset} =
               %SequenceVersion{}
               |> SequenceVersion.changeset(attrs)
               |> TestRepo.insert()

      assert %{state: [_message]} = errors_on(changeset)
    end

    test "activation rejects a second active version when another insert wins the race" do
      sequence = Fixtures.sequence_fixture()
      _first = Fixtures.sequence_version_fixture(sequence, %{version: 1, state: "active"})
      second = Fixtures.sequence_version_fixture(sequence, %{version: 2})

      assert %Postgrex.Error{postgres: %{code: :unique_violation}} =
               catch_error(
                 TestRepo.update_all(
                   from(version in SequenceVersion, where: version.id == ^second.id),
                   set: [state: "active"]
                 )
               )
    end
  end

  describe "steps" do
    test "creates an immediate email step with defaults" do
      version = version_fixture()

      assert {:ok, step} =
               DripDrop.create_step(version.id, %{
                 name: "Welcome",
                 key: "welcome",
                 position: 1,
                 channel: "email",
                 timing: %{type: "immediate"},
                 template_content: email_template()
               })

      assert step.channel == "email"
      assert step.template_type == "inline"
      assert step.active
      assert is_nil(step.channel_adapter_id)
    end

    test "rejects unknown channels" do
      version = version_fixture()

      assert {:error, changeset} =
               DripDrop.create_step(version.id, %{
                 name: "Fax",
                 key: "fax",
                 position: 1,
                 channel: "fax",
                 timing: %{type: "immediate"},
                 template_content: %{}
               })

      assert %{channel: [_message]} = errors_on(changeset)
    end

    test "rejects duplicate step keys in a version" do
      version = version_fixture()
      Fixtures.step_fixture(version, %{key: "welcome", template_content: email_template()})

      assert {:error, changeset} =
               DripDrop.create_step(version.id, %{
                 name: "Welcome Again",
                 key: "welcome",
                 position: 2,
                 channel: "email",
                 timing: %{type: "immediate"},
                 template_content: email_template()
               })

      assert %{key: [_message]} = errors_on(changeset)
    end
  end

  describe "conditions" do
    test "creates hook and HTTP-hook references" do
      version = version_fixture(%{hook_module: "#{Hooks}"})
      step = Fixtures.step_fixture(version, %{template_content: email_template()})

      assert {:ok, hook_condition} =
               DripDrop.create_condition(step.id, %{
                 condition_type: "hook",
                 hook_function: "setup_completed",
                 operator: "==",
                 expected_value: "true"
               })

      assert hook_condition.hook_function == "setup_completed"

      http_hook = Fixtures.http_hook_fixture(version.sequence_id)

      assert {:ok, http_condition} =
               DripDrop.create_condition(step.id, %{
                 condition_type: "hook",
                 http_hook_id: http_hook.id,
                 operator: "==",
                 expected_value: "true"
               })

      assert http_condition.http_hook_id == http_hook.id
    end

    test "rejects dangling HTTP-hook references through the foreign key" do
      version = version_fixture()
      step = Fixtures.step_fixture(version, %{template_content: email_template()})

      assert {:error, changeset} =
               DripDrop.create_condition(step.id, %{
                 condition_type: "hook",
                 http_hook_id: Ecto.UUID.generate(),
                 operator: "==",
                 expected_value: "true"
               })

      assert %{http_hook_id: [_message]} = errors_on(changeset)
    end

    test "numeric coercion failures fail closed and emit condition telemetry" do
      attach_telemetry([:dripdrop, :condition, :coercion_error])

      sequence = Fixtures.sequence_fixture()
      version = Fixtures.sequence_version_fixture(sequence, %{state: "active"})

      current_step =
        Fixtures.step_fixture(version, %{
          key: "score-check",
          config: %{"quiet_hours" => false},
          template_content: email_template()
        })

      next_step = Fixtures.step_fixture(version, %{key: "enterprise-path", position: 2})

      Fixtures.channel_adapter_fixture(%{
        tenant_key: sequence.tenant_key,
        provider: "authoring_test",
        is_default: true
      })

      {:ok, transition} =
        DripDrop.create_step_transition(version.id, %{
          from_step_id: current_step.id,
          to_step_id: next_step.id,
          condition_mode: "all",
          priority: 0
        })

      assert {:ok, condition} =
               DripDrop.create_condition(transition.id, %{
                 transition_id: transition.id,
                 condition_type: "enrollment_data",
                 field_path: "$.score",
                 operator: ">",
                 expected_value: "10"
               })

      assert [%Condition{id: condition_id}] = TestRepo.preload(transition, :conditions).conditions
      assert condition_id == condition.id

      enrollment =
        Fixtures.enrollment_fixture(sequence, version, %{
          data: %{"score" => "abc"}
        })

      execution = Fixtures.step_execution_fixture(enrollment, current_step)

      assert :ok = DispatchStep.perform(%{step_execution_id: execution.id})

      assert TestRepo.get!(StepExecution, execution.id).state == "sent"

      assert_receive {:telemetry, [:dripdrop, :condition, :coercion_error], %{count: 1},
                      %{
                        condition_id: condition_id,
                        step_execution_id: step_execution_id,
                        field_path: "$.score",
                        operator: ">",
                        expected_value: "10",
                        actual_value: "abc"
                      }}

      assert condition_id == condition.id
      assert step_execution_id == execution.id

      refute TestRepo.exists?(
               from(step_execution in StepExecution,
                 where: step_execution.enrollment_id == ^enrollment.id,
                 where: step_execution.step_id == ^next_step.id
               )
             )
    end

    test "routes by transition priority and falls through when the first condition is false" do
      %{sequence: sequence, version: version, current_step: current_step} =
        dispatchable_version(%{hook_module: "#{Hooks}"})

      condition_path = Fixtures.step_fixture(version, %{key: "condition-path", position: 2})
      fallback_path = Fixtures.step_fixture(version, %{key: "fallback-path", position: 3})

      {:ok, first_transition} =
        DripDrop.create_step_transition(version.id, %{
          from_step_id: current_step.id,
          to_step_id: condition_path.id,
          condition_mode: "all",
          priority: 0
        })

      assert {:ok, _condition} =
               DripDrop.create_condition(first_transition.id, %{
                 transition_id: first_transition.id,
                 condition_type: "hook",
                 hook_function: "setup_completed",
                 operator: "==",
                 expected_value: "false"
               })

      assert {:ok, _fallback_transition} =
               DripDrop.create_step_transition(version.id, %{
                 from_step_id: current_step.id,
                 to_step_id: fallback_path.id,
                 condition_mode: "always",
                 priority: 1
               })

      enrollment = Fixtures.enrollment_fixture(sequence, version)
      execution = Fixtures.step_execution_fixture(enrollment, current_step)

      assert :ok = DispatchStep.perform(%{step_execution_id: execution.id})

      assert TestRepo.exists?(
               from(step_execution in StepExecution,
                 where: step_execution.enrollment_id == ^enrollment.id,
                 where: step_execution.step_id == ^fallback_path.id
               )
             )

      refute TestRepo.exists?(
               from(step_execution in StepExecution,
                 where: step_execution.enrollment_id == ^enrollment.id,
                 where: step_execution.step_id == ^condition_path.id
               )
             )
    end

    test "linear ordering fallback schedules the next positioned step without transitions" do
      %{sequence: sequence, version: version, current_step: current_step} = dispatchable_version()
      next_step = Fixtures.step_fixture(version, %{key: "next", position: 2})
      enrollment = Fixtures.enrollment_fixture(sequence, version)
      execution = Fixtures.step_execution_fixture(enrollment, current_step)

      assert :ok = DispatchStep.perform(%{step_execution_id: execution.id})

      assert TestRepo.exists?(
               from(step_execution in StepExecution,
                 where: step_execution.enrollment_id == ^enrollment.id,
                 where: step_execution.step_id == ^next_step.id,
                 where: step_execution.state == "scheduled"
               )
             )
    end

    test "explicit completion edge marks the enrollment completed" do
      %{sequence: sequence, version: version, current_step: current_step} = dispatchable_version()

      assert {:ok, _transition} =
               DripDrop.create_step_transition(version.id, %{
                 from_step_id: current_step.id,
                 to_step_id: nil,
                 condition_mode: "always",
                 priority: 0
               })

      enrollment = Fixtures.enrollment_fixture(sequence, version)
      execution = Fixtures.step_execution_fixture(enrollment, current_step)

      assert :ok = DispatchStep.perform(%{step_execution_id: execution.id})

      assert TestRepo.get!(Enrollment, enrollment.id).state == "completed"
    end

    test "hook branch can positively match false values" do
      %{sequence: sequence, version: version, current_step: current_step} =
        dispatchable_version(%{hook_module: "#{Hooks}"})

      false_path = Fixtures.step_fixture(version, %{key: "false-path", position: 2})

      {:ok, transition} =
        DripDrop.create_step_transition(version.id, %{
          from_step_id: current_step.id,
          to_step_id: false_path.id,
          condition_mode: "all",
          priority: 0
        })

      assert {:ok, _condition} =
               DripDrop.create_condition(transition.id, %{
                 transition_id: transition.id,
                 condition_type: "hook",
                 hook_function: "setup_incomplete",
                 operator: "==",
                 expected_value: "false"
               })

      enrollment = Fixtures.enrollment_fixture(sequence, version)
      execution = Fixtures.step_execution_fixture(enrollment, current_step)

      assert :ok = DispatchStep.perform(%{step_execution_id: execution.id})

      assert TestRepo.exists?(
               from(step_execution in StepExecution,
                 where: step_execution.enrollment_id == ^enrollment.id,
                 where: step_execution.step_id == ^false_path.id
               )
             )
    end

    test "enrollment-data JSONPath comparisons can positively match a branch" do
      %{sequence: sequence, version: version, current_step: current_step} = dispatchable_version()
      enterprise_path = Fixtures.step_fixture(version, %{key: "enterprise-path", position: 2})

      {:ok, transition} =
        DripDrop.create_step_transition(version.id, %{
          from_step_id: current_step.id,
          to_step_id: enterprise_path.id,
          condition_mode: "all",
          priority: 0
        })

      assert {:ok, _condition} =
               DripDrop.create_condition(transition.id, %{
                 transition_id: transition.id,
                 condition_type: "enrollment_data",
                 field_path: "$.plan_tier",
                 operator: "==",
                 expected_value: "enterprise"
               })

      enrollment =
        Fixtures.enrollment_fixture(sequence, version, %{
          data: %{"plan_tier" => "enterprise"}
        })

      execution = Fixtures.step_execution_fixture(enrollment, current_step)

      assert :ok = DispatchStep.perform(%{step_execution_id: execution.id})

      assert TestRepo.exists?(
               from(step_execution in StepExecution,
                 where: step_execution.enrollment_id == ^enrollment.id,
                 where: step_execution.step_id == ^enterprise_path.id
               )
             )
    end
  end

  describe "authoring validation" do
    test "accepts a positioned sequence version" do
      version = version_fixture(%{hook_module: "#{Hooks}"})
      step = Fixtures.step_fixture(version, %{template_content: email_template()})

      assert {:ok, _condition} =
               DripDrop.create_condition(step.id, %{
                 condition_type: "hook",
                 hook_function: "setup_completed",
                 operator: "==",
                 expected_value: "true"
               })

      assert {:ok, validated} = DripDrop.validate_sequence_version(version.id)
      assert validated.id == version.id
    end

    test "returns no-entry-path when no entry transition or positioned step exists" do
      version = version_fixture()
      Fixtures.step_fixture(version, %{position: nil, template_content: email_template()})

      assert {:error, errors} = DripDrop.validate_sequence_version(version.id)
      assert {:no_entry_path, _message} = List.keyfind(errors, :no_entry_path, 0)
    end

    test "reports cron expression parse failures" do
      version = version_fixture()

      step =
        Fixtures.step_fixture(version, %{
          key: "digest",
          timing: %{type: "cron", cron_expression: "@daily"},
          template_content: email_template()
        })

      assert %Postgrex.Result{num_rows: 1} =
               TestRepo.query!(
                 """
                 UPDATE dripdrop.steps
                 SET timing = $1::jsonb
                 WHERE id = $2::uuid
                 """,
                 [
                   %{type: "cron", cron_expression: "every blursday"},
                   DBHelpers.dump_uuid(step.id)
                 ]
               )

      assert {:error, errors} = DripDrop.validate_sequence_version(version.id)
      assert {:invalid_cron, "digest", _reason} = List.keyfind(errors, :invalid_cron, 0)
    end

    test "reports structurally invalid predicate conditions already present in the database" do
      version = version_fixture()
      step = Fixtures.step_fixture(version, %{template_content: email_template()})

      condition =
        %Condition{}
        |> Condition.changeset(%{
          step_id: step.id,
          condition_type: "predicate",
          operator: "==",
          config: %{"predicate" => "plan == 'pro'"}
        })
        |> TestRepo.insert!()

      {1, nil} =
        Condition
        |> where([condition], condition.id == ^condition.id)
        |> TestRepo.update_all(set: [config: %{"predicate" => %{"bad" => "shape"}}])

      assert {:error, errors} = DripDrop.validate_sequence_version(version.id)

      assert {:invalid_condition, condition.id, {:predicate, :invalid_predicate}} in errors
    end

    test "reports adapter rotation references that do not exist" do
      version = version_fixture()
      missing_adapter_id = Ecto.UUID.generate()

      Fixtures.step_fixture(version, %{
        key: "digest",
        config: %{"channel_adapter_rotation" => [%{"adapter_id" => missing_adapter_id}]},
        template_content: email_template()
      })

      assert {:error, errors} = DripDrop.validate_sequence_version(version.id)

      assert {:missing_channel_adapter, "digest", ^missing_adapter_id} =
               List.keyfind(errors, :missing_channel_adapter, 0)
    end

    test "reports hook functions that cannot resolve on the sequence hook module" do
      version = version_fixture(%{hook_module: "#{Hooks}"})
      step = Fixtures.step_fixture(version, %{template_content: email_template()})

      assert {:ok, _condition} =
               DripDrop.create_condition(step.id, %{
                 condition_type: "hook",
                 hook_function: "missing_function",
                 operator: "==",
                 expected_value: "true"
               })

      assert {:error, errors} = DripDrop.validate_sequence_version(version.id)

      assert {:missing_hook_function, "missing_function", _reason} =
               List.keyfind(errors, :missing_hook_function, 0)
    end
  end

  defp version_fixture(sequence_attrs \\ %{}) do
    sequence = Fixtures.sequence_fixture(sequence_attrs)
    Fixtures.sequence_version_fixture(sequence)
  end

  defp email_template do
    %{"subject" => "Welcome", "text" => "Hello"}
  end

  defp dispatchable_version(sequence_attrs \\ %{}) do
    sequence = Fixtures.sequence_fixture(sequence_attrs)
    version = Fixtures.sequence_version_fixture(sequence, %{state: "active"})

    current_step =
      Fixtures.step_fixture(version, %{
        key: "current",
        position: 1,
        config: %{"quiet_hours" => false},
        template_content: email_template()
      })

    Fixtures.channel_adapter_fixture(%{
      tenant_key: sequence.tenant_key,
      provider: "authoring_test",
      is_default: true
    })

    %{sequence: sequence, version: version, current_step: current_step}
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

  defp register_test_provider do
    registry_key = {Channels, :providers}
    previous_providers = :persistent_term.get(registry_key, %{})

    providers =
      previous_providers
      |> Map.put_new(:email, %{})
      |> put_in([:email, :authoring_test], AuthoringTestProvider)

    :persistent_term.put(registry_key, providers)
    on_exit(fn -> :persistent_term.put(registry_key, previous_providers) end)
  end
end
