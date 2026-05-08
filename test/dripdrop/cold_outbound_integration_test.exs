defmodule DripDrop.ColdOutboundIntegrationTest do
  use DripDrop.DataCase, async: false

  @moduletag :integration

  alias DripDrop.Channel
  alias DripDrop.Channels
  alias DripDrop.Channels.Provider

  alias DripDrop.{
    AdapterHealth,
    AdapterPools,
    AdapterPools.WDRR,
    ChannelAdapter,
    Dispatch,
    Enrollment,
    Fixtures,
    MessageEvent,
    StepExecution,
    Templates.Spintax,
    TestRepo
  }

  alias DripDrop.Jobs.DispatchStep
  alias DripDrop.Policy.BounceComplaintThresholds

  defmodule RecorderProvider do
    @moduledoc false
    use Provider

    @impl Channel
    def deliver(step, enrollment, adapter) do
      payload = get_in(step.config || %{}, ["payload"]) || %{}
      recorder = adapter.config["recorder"] || adapter.config[:recorder]

      if is_binary(recorder) do
        Agent.update({:global, recorder}, fn deliveries ->
          [
            %{
              adapter_id: adapter.id,
              enrollment_id: enrollment.id,
              step_key: step.key,
              payload: payload
            }
            | deliveries
          ]
        end)
      end

      case adapter.config["result"] do
        "temporary_error" ->
          {:error, %{kind: :temporary, reason: :rate_limited}}

        _success ->
          {:ok,
           %{
             provider_message_id: "msg_#{payload[:idempotency_key]}",
             response: %{status: "accepted"}
           }}
      end
    end
  end

  setup do
    recorder = "cold-outbound-recorder-#{System.unique_integer([:positive])}"
    {:ok, _agent} = Agent.start_link(fn -> [] end, name: {:global, recorder})
    register_test_provider()
    WDRR.reset!()

    on_exit(fn ->
      case :global.whereis_name(recorder) do
        :undefined -> :ok
        pid -> Agent.stop(pid)
      end
    end)

    {:ok, recorder: recorder}
  end

  test "lifecycle rotation still re-rolls across steps in the same enrollment", %{
    recorder: recorder
  } do
    sequence = Fixtures.sequence_fixture(%{tenant_key: "tenant-a"})

    adapters =
      for name <- ~w(a b c) do
        adapter_fixture(recorder, %{tenant_key: sequence.tenant_key, name: "Lifecycle #{name}"})
      end

    rotation = Enum.map(adapters, &%{"adapter_id" => &1.id, "weight" => 1})

    version = Fixtures.sequence_version_fixture(sequence, %{state: "draft"})

    first =
      Fixtures.step_fixture(version, %{
        key: "first",
        position: 1,
        config: %{"quiet_hours" => false, "channel_adapter_rotation" => rotation},
        template_content: %{
          "from" => "team@example.com",
          "subject" => "First",
          "text" => "First"
        }
      })

    second =
      Fixtures.step_fixture(version, %{
        key: "second",
        position: 2,
        config: %{"quiet_hours" => false, "channel_adapter_rotation" => rotation},
        template_content: %{
          "from" => "team@example.com",
          "subject" => "Second",
          "text" => "Second"
        }
      })

    {:ok, _version} = DripDrop.activate_sequence_version(version.id)

    pairs =
      for index <- 1..50 do
        {:ok, enrollment} =
          DripDrop.enroll(%{
            sequence_id: sequence.id,
            subscriber_type: "lead",
            subscriber_id: "lead-#{index}",
            tenant_key: sequence.tenant_key,
            data: %{"email" => "lead-#{index}@example.com"}
          })

        first_execution = step_execution!(enrollment.id, first.id)
        assert :ok = DispatchStep.perform(%{step_execution_id: first_execution.id})

        second_execution = step_execution!(enrollment.id, second.id)
        assert :ok = DispatchStep.perform(%{step_execution_id: second_execution.id})

        sent_adapter_pair(enrollment.id, first.id, second.id)
      end

    assert Enum.any?(pairs, fn {first_adapter_id, second_adapter_id} ->
             first_adapter_id != second_adapter_id
           end)
  end

  test "foundation README scenarios run without outbound configuration", %{recorder: recorder} do
    Enum.each(
      [
        {"onboarding", ["welcome", "activation"]},
        {"lead-nurture", ["educate", "invite"]},
        {"multi-channel-trial", ["email-day-0", "email-day-2"]}
      ],
      fn {key, step_keys} ->
        scenario = lifecycle_scenario(recorder, key, step_keys)

        {:ok, enrollment} =
          DripDrop.enroll(%{
            sequence_id: scenario.sequence.id,
            subscriber_type: "user",
            subscriber_id: "#{key}-user",
            tenant_key: scenario.sequence.tenant_key,
            data: %{"email" => "#{key}@example.com", "first_name" => "Sam"}
          })

        for step <- scenario.steps do
          execution = step_execution!(enrollment.id, step.id)
          assert :ok = DispatchStep.perform(%{step_execution_id: execution.id})
          assert TestRepo.get!(StepExecution, execution.id).out_message_id == nil
        end

        assert TestRepo.get!(Enrollment, enrollment.id).state == "completed"
      end
    )
  end

  test "outbound sequence pins each enrollment and ramp cap defers at adapter limit", %{
    recorder: recorder
  } do
    scenario = outbound_scenario(recorder, adapter_count: 3)

    enrollments =
      for index <- 1..30 do
        outbound_enroll!(scenario.sequence, index)
      end

    counts = Enum.frequencies_by(enrollments, & &1.adapter_id)

    assert map_size(counts) == 3
    assert Enum.all?(Map.values(counts), &(&1 in 8..12))

    enrollment = hd(enrollments)
    execution = first_execution!(enrollment.id)

    assert :ok = DispatchStep.perform(%{step_execution_id: execution.id})
    first_adapter_id = delivery_for(recorder, enrollment.id, "outbound-1").adapter_id

    next_execution = next_execution!(enrollment.id)
    assert :ok = DispatchStep.perform(%{step_execution_id: next_execution.id})
    assert delivery_for(recorder, enrollment.id, "outbound-2").adapter_id == first_adapter_id

    capped_enrollment =
      Enum.find(enrollments, &(&1.adapter_id == first_adapter_id and &1.id != enrollment.id))

    capped_execution = first_execution!(capped_enrollment.id)
    adapter = TestRepo.get!(ChannelAdapter, first_adapter_id)

    adapter
    |> ChannelAdapter.changeset(%{daily_cap: 1})
    |> TestRepo.update!()

    assert :ok = DispatchStep.perform(%{step_execution_id: capped_execution.id})
    assert TestRepo.get!(StepExecution, capped_execution.id).state == "scheduled"
  end

  test "outbound min-gap defers concurrent sends on the same adapter", %{recorder: recorder} do
    scenario =
      outbound_scenario(recorder, adapter_count: 1, adapter_attrs: %{min_gap_seconds: 90})

    enrollments = for index <- 1..5, do: outbound_enroll!(scenario.sequence, index)
    [first | rest] = enrollments

    assert :ok = DispatchStep.perform(%{step_execution_id: first_execution!(first.id).id})
    adapter = TestRepo.get!(ChannelAdapter, first.adapter_id)
    assert %DateTime{} = adapter.last_send_at

    for enrollment <- rest do
      execution = first_execution!(enrollment.id)
      assert :ok = DispatchStep.perform(%{step_execution_id: execution.id})

      reloaded = TestRepo.get!(StepExecution, execution.id)
      assert reloaded.state == "scheduled"

      assert DateTime.compare(
               reloaded.scheduled_for,
               DateTime.add(adapter.last_send_at, 89, :second)
             ) ==
               :gt
    end
  end

  test "adapter bounce health routes new pins around resting and resumes after probe success", %{
    recorder: recorder
  } do
    previous_thresholds = Application.get_env(:dripdrop, :bounce_complaint_thresholds)

    Application.put_env(:dripdrop, :bounce_complaint_thresholds,
      bounce_rate: 0.2,
      complaint_rate: 1.0,
      pause_seconds: 60
    )

    on_exit(fn ->
      Application.put_env(:dripdrop, :bounce_complaint_thresholds, previous_thresholds)
    end)

    scenario = outbound_scenario(recorder, adapter_count: 2)
    [adapter_a, adapter_b] = scenario.adapters

    for _index <- 1..5 do
      insert_adapter_event(adapter_a.id, "sent")
    end

    insert_adapter_event(adapter_a.id, "bounced")

    assert {:ok, 1} = BounceComplaintThresholds.check_all()
    resting = TestRepo.get!(ChannelAdapter, adapter_a.id)
    assert resting.health_state == :resting

    pins =
      for index <- 1..4 do
        outbound_enroll!(scenario.sequence, index).adapter_id
      end

    refute adapter_a.id in pins
    assert Enum.all?(pins, &(&1 == adapter_b.id))

    resting
    |> ChannelAdapter.changeset(%{
      resting_until: DateTime.add(DateTime.utc_now(:second), -1, :second)
    })
    |> TestRepo.update!()

    assert {:ok, probing} =
             AdapterHealth.recover_if_due(TestRepo.get!(ChannelAdapter, adapter_a.id))

    assert probing.health_state == :probing

    for _index <- 1..5 do
      insert_adapter_event(adapter_a.id, "sent")
    end

    assert {:ok, ramping} = AdapterHealth.evaluate_probe(probing)
    assert ramping.health_state == :ramping

    pins_after_recovery =
      for index <- 5..12 do
        outbound_enroll!(scenario.sequence, index).adapter_id
      end

    assert adapter_a.id in pins_after_recovery
  end

  test "outbound threading supports host-fed reply ingestion and pauses enrollment", %{
    recorder: recorder
  } do
    scenario =
      outbound_scenario(recorder,
        adapter_count: 1,
        step_count: 4,
        step_config: %{"quiet_hours" => false, "reply_behavior" => "pause_enrollment"}
      )

    enrollment = outbound_enroll!(scenario.sequence, 1)

    sent =
      for step <- Enum.take(scenario.steps, 3) do
        execution = step_execution!(enrollment.id, step.id)
        assert :ok = DispatchStep.perform(%{step_execution_id: execution.id})
        TestRepo.get!(StepExecution, execution.id)
      end

    assert Enum.all?(sent, &is_binary(&1.out_message_id))
    [first, second, third] = sent
    assert first.out_message_id != second.out_message_id
    assert second.out_message_id != third.out_message_id

    assert :ok =
             DripDrop.ingest_inbound_message(enrollment.adapter_id, %{
               message_id: "reply@example.net",
               in_reply_to: third.out_message_id,
               references: Enum.map(sent, & &1.out_message_id),
               from: "prospect@example.net",
               to: "sender@example.com",
               subject: "Re: hello",
               body_text: "Interested",
               received_at: DateTime.utc_now(:second),
               intent: :reply
             })

    assert TestRepo.get!(Enrollment, enrollment.id).state == "paused"

    assert TestRepo.exists?(
             from(event in MessageEvent,
               where: event.step_execution_id == ^third.id,
               where: event.event_type == "replied",
               where: event.in_reply_to == ^strip_angles(third.out_message_id)
             )
           )
  end

  test "outbound spintax is retry-stable and replay can vary output", %{recorder: recorder} do
    scenario =
      outbound_scenario(recorder,
        adapter_count: 1,
        adapter_config: %{"result" => "temporary_error"},
        step_count: 1,
        step_config: %{
          "quiet_hours" => false,
          "max_retries" => 3,
          "template_variation" => %{"spintax" => true}
        },
        template_content: %{
          "from" => "sender@example.com",
          "subject" => "{Hi|Hello|Hey}",
          "text" => "{A|B|C} body"
        }
      )

    enrollment = outbound_enroll!(scenario.sequence, 1)
    execution = first_execution!(enrollment.id)

    assert :ok = DispatchStep.perform(%{step_execution_id: execution.id})
    assert :ok = DispatchStep.perform(%{step_execution_id: execution.id})

    [retry_delivery, first_delivery | _] = deliveries(recorder)
    assert retry_delivery.payload.subject == first_delivery.payload.subject
    assert retry_delivery.payload.text == first_delivery.payload.text

    failed =
      StepExecution
      |> TestRepo.get!(execution.id)
      |> StepExecution.changeset(%{state: "claiming"})
      |> TestRepo.update!()
      |> StepExecution.changeset(%{state: "failed"})
      |> TestRepo.update!()

    assert {:ok, replayed} = Dispatch.replay(failed.id)

    assert replayed.attempt_window == failed.attempt_window + 1

    {original, replay} = replay_variants!(hd(scenario.steps), failed, replayed)
    assert original.text != replay.text
  end

  test "WDRR property distribution is statistically close to configured weights", %{
    recorder: recorder
  } do
    sequence = Fixtures.sequence_fixture(%{tenant_key: "tenant-a"})
    pool = Fixtures.adapter_pool_fixture(%{tenant_key: sequence.tenant_key})

    weights = [a: 5, b: 3, c: 2]

    adapters =
      for {name, weight} <- weights do
        adapter =
          adapter_fixture(recorder, %{
            tenant_key: sequence.tenant_key,
            name: "#{name}",
            health_state: :active
          })

        Fixtures.adapter_pool_member_fixture(pool, adapter, %{weight: weight})
        adapter
      end

    version =
      Fixtures.sequence_version_fixture(sequence, %{
        state: "active",
        mode: :outbound,
        config: %{"pool_id" => pool.id}
      })

    picks =
      for _index <- 1..1000 do
        {:ok, member} = AdapterPools.WDRR.pick_member(pool, version)
        member.adapter_id
      end

    counts = Enum.frequencies(picks)
    [a, b, c] = adapters

    assert counts[a.id] in 475..525
    assert counts[b.id] in 275..325
    assert counts[c.id] in 175..225
  end

  defp lifecycle_scenario(recorder, key, step_keys) do
    sequence = Fixtures.sequence_fixture(%{tenant_key: "tenant-a", key: key})
    adapter = adapter_fixture(recorder, %{tenant_key: sequence.tenant_key, is_default: true})
    version = Fixtures.sequence_version_fixture(sequence, %{state: "draft"})

    steps =
      step_keys
      |> Enum.with_index(1)
      |> Enum.map(fn {step_key, position} ->
        Fixtures.step_fixture(version, %{
          key: step_key,
          position: position,
          channel_adapter_id: adapter.id,
          config: %{"quiet_hours" => false},
          template_content: %{
            "from" => "team@example.com",
            "subject" => "Welcome {{ first_name }}",
            "text" => "Hello {{ first_name }}"
          }
        })
      end)

    {:ok, _version} = DripDrop.activate_sequence_version(version.id)
    %{sequence: sequence, version: version, adapter: adapter, steps: steps}
  end

  defp outbound_scenario(recorder, opts) do
    sequence = Fixtures.sequence_fixture(%{tenant_key: "tenant-a"})
    pool = Fixtures.adapter_pool_fixture(%{tenant_key: sequence.tenant_key})
    adapter_count = Keyword.get(opts, :adapter_count, 1)
    adapter_config = Keyword.get(opts, :adapter_config, %{})
    adapter_attrs = Keyword.get(opts, :adapter_attrs, %{})

    adapters =
      for index <- 1..adapter_count do
        attrs =
          %{
            tenant_key: sequence.tenant_key,
            name: "Outbound #{index}",
            health_state: :active,
            config: Map.put(adapter_config, "recorder", recorder)
          }
          |> Map.merge(adapter_attrs)

        adapter = adapter_fixture(recorder, attrs)
        Fixtures.adapter_pool_member_fixture(pool, adapter)
        adapter
      end

    version =
      Fixtures.sequence_version_fixture(sequence, %{
        state: "draft",
        mode: :outbound,
        config: %{"pool_id" => pool.id}
      })

    step_count = Keyword.get(opts, :step_count, 2)
    base_step_config = Keyword.get(opts, :step_config, %{"quiet_hours" => false})

    steps =
      for position <- 1..step_count do
        Fixtures.step_fixture(version, %{
          key: "outbound-#{position}",
          position: position,
          config: base_step_config,
          template_content:
            Keyword.get(opts, :template_content, %{
              "from" => "sender@example.com",
              "subject" => "Step #{position}",
              "text" => "Step #{position}"
            })
        })
      end

    {:ok, _version} = DripDrop.activate_sequence_version(version.id)

    %{sequence: sequence, version: version, pool: pool, adapters: adapters, steps: steps}
  end

  defp outbound_enroll!(sequence, index) do
    {:ok, enrollment} =
      DripDrop.enroll(%{
        sequence_id: sequence.id,
        subscriber_type: "lead",
        subscriber_id: "outbound-lead-#{index}",
        tenant_key: sequence.tenant_key,
        data: %{"email" => "outbound-#{index}@example.com"}
      })

    enrollment
  end

  defp adapter_fixture(recorder, attrs) do
    attrs =
      %{
        provider: "cold_recorder",
        channel: "email",
        config: %{"recorder" => recorder},
        health_state: :active,
        active: true
      }
      |> Map.merge(attrs)
      |> update_in([:config], fn
        nil -> %{"recorder" => recorder}
        config -> Map.put_new(config, "recorder", recorder)
      end)

    Fixtures.channel_adapter_fixture(attrs)
  end

  defp step_execution!(enrollment_id, step_id) do
    TestRepo.one!(
      from(execution in StepExecution,
        where: execution.enrollment_id == ^enrollment_id,
        where: execution.step_id == ^step_id
      )
    )
  end

  defp first_execution!(enrollment_id) do
    TestRepo.one!(
      from(execution in StepExecution,
        where: execution.enrollment_id == ^enrollment_id,
        order_by: [asc: execution.inserted_at],
        limit: 1
      )
    )
  end

  defp next_execution!(enrollment_id) do
    TestRepo.one!(
      from(execution in StepExecution,
        where: execution.enrollment_id == ^enrollment_id,
        where: execution.state == "scheduled",
        order_by: [asc: execution.inserted_at],
        limit: 1
      )
    )
  end

  defp sent_adapter_pair(enrollment_id, first_step_id, second_step_id) do
    first = step_execution!(enrollment_id, first_step_id)
    second = step_execution!(enrollment_id, second_step_id)
    {adapter_id_for(first.id), adapter_id_for(second.id)}
  end

  defp adapter_id_for(step_execution_id) do
    TestRepo.one!(
      from(event in MessageEvent,
        where: event.step_execution_id == ^step_execution_id,
        where: event.event_type == "sent",
        select: fragment("?->>'adapter_id'", event.event_data)
      )
    )
  end

  defp insert_adapter_event(adapter_id, event_type) do
    Fixtures.message_event_fixture(%{
      tenant_key: "tenant-a",
      event_type: event_type,
      event_data: %{"adapter_id" => adapter_id}
    })
  end

  defp delivery_for(recorder, enrollment_id, step_key) do
    Enum.find(deliveries(recorder), fn delivery ->
      delivery.enrollment_id == enrollment_id and delivery.step_key == step_key
    end)
  end

  defp deliveries(recorder), do: Agent.get({:global, recorder}, & &1)

  defp replay_variants!(step, failed, replayed) do
    2..100
    |> Enum.find_value(fn option_count ->
      options = Enum.map_join(1..option_count, "|", &"option-#{&1}")
      payload = %{text: "{#{options}} body"}
      original = Spintax.apply(payload, step, failed)
      replay = Spintax.apply(payload, step, replayed)

      if original.text != replay.text, do: {original, replay}
    end)
    |> case do
      nil ->
        flunk("expected at least one spintax payload to differ across replay attempt windows")

      variants ->
        variants
    end
  end

  defp strip_angles("<" <> rest), do: String.trim_trailing(rest, ">")
  defp strip_angles(value), do: value

  defp register_test_provider do
    registry_key = {Channels, :providers}
    previous_providers = :persistent_term.get(registry_key, %{})

    providers =
      previous_providers
      |> Map.put_new(:email, %{})
      |> put_in([:email, :cold_recorder], RecorderProvider)

    :persistent_term.put(registry_key, providers)
    on_exit(fn -> :persistent_term.put(registry_key, previous_providers) end)
  end
end
