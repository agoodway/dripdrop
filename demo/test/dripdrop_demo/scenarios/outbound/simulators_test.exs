defmodule DripdropDemo.Scenarios.Outbound.SimulatorsTest do
  use DripdropDemo.DataCase

  import Ecto.Query

  alias DripDrop.{ChannelAdapter, Enrollment, MessageEvent, StepExecution, Suppression}
  alias DripDrop.Jobs.DispatchStep
  alias DripdropDemo.Repo
  alias DripdropDemo.Scenarios.Outbound
  alias DripdropDemo.Scenarios.Outbound.Simulators

  setup do
    Code.eval_file("priv/repo/seeds.exs")
    {:ok, enrollments} = Outbound.enroll_prospects()
    rows = Outbound.list_enrollments(Enum.map(enrollments, & &1.id))
    %{rows: rows}
  end

  test "ghost outcome is a no-op", %{rows: rows} do
    mia = row!(rows, "Mia")

    assert :ok = Simulators.trigger(mia.id, :ghost)

    refute Repo.exists?(
             from(event in MessageEvent,
               where: event.provider_event_id == ^"demo-ghost-#{mia.id}"
             )
           )
  end

  test "positive reply inserts a replied event and pauses the enrollment", %{rows: rows} do
    jordan = row!(rows, "Jordan")
    dispatch_first_step!(jordan.id)

    assert :ok = Simulators.trigger(jordan.id, :reply_positive)

    assert Repo.get!(Enrollment, jordan.id).state == "paused"

    assert Repo.exists?(
             from(event in MessageEvent,
               where: event.event_type == "replied",
               where: event.provider_event_id == ^"demo-positive-#{jordan.id}@reply.dripdrop.dev"
             )
           )
  end

  test "ooo reply inserts a replied event with ooo intent", %{rows: rows} do
    priya = row!(rows, "Priya")
    dispatch_first_step!(priya.id)

    assert :ok = Simulators.trigger(priya.id, :reply_ooo)

    event =
      Repo.one!(
        from(event in MessageEvent,
          where: event.event_type == "replied",
          where: event.provider_event_id == ^"demo-ooo-#{priya.id}@reply.dripdrop.dev"
        )
      )

    assert event.event_data["intent"] in [:ooo, "ooo"]
    assert event.event_data["intent_data"]["demo"] == true
  end

  test "hard bounce inserts a bounce event and suppresses the recipient", %{rows: rows} do
    eli = row!(rows, "Eli")
    dispatch_first_step!(eli.id)

    assert :ok = Simulators.trigger(eli.id, :hard_bounce)

    assert Repo.exists?(
             from(event in MessageEvent,
               where: event.event_type == "bounced",
               where: event.event_data["severity"] == "permanent"
             )
           )

    assert Repo.exists?(
             from(suppression in Suppression,
               where: suppression.tenant_key == "demo",
               where: suppression.recipient_normalized == "eli@runway.example",
               where: suppression.reason == "bounce"
             )
           )
  end

  test "soft bounce inserts a temporary bounce event without suppression", %{rows: rows} do
    nora = row!(rows, "Nora")
    dispatch_first_step!(nora.id)

    assert :ok = Simulators.trigger(nora.id, :soft_bounce)

    assert Repo.exists?(
             from(event in MessageEvent,
               where: event.event_type == "bounced",
               where: event.event_data["severity"] == "temporary"
             )
           )

    refute Repo.exists?(
             from(suppression in Suppression,
               where: suppression.tenant_key == "demo",
               where: suppression.recipient_normalized == "nora@stackpilot.example"
             )
           )
  end

  test "unsubscribe inserts an unsubscribe event and suppression", %{rows: rows} do
    theo = row!(rows, "Theo")
    dispatch_first_step!(theo.id)

    assert :ok = Simulators.trigger(theo.id, :unsubscribe)

    assert Repo.exists?(
             from(event in MessageEvent,
               where: event.event_type == "unsubscribed",
               where: event.provider_event_id == ^"demo-unsubscribe-#{theo.id}"
             )
           )

    assert Repo.exists?(
             from(suppression in Suppression,
               where: suppression.tenant_key == "demo",
               where: suppression.recipient_normalized == "theo@opscanvas.example",
               where: suppression.reason == "unsubscribe"
             )
           )
  end

  test "ramp cap records a deferred event without wedging the shared sender", %{rows: rows} do
    avery = row!(rows, "Avery")
    dispatch_first_step!(avery.id)

    assert :ok = Simulators.trigger(avery.id, :ramp_cap)

    assert Repo.get!(ChannelAdapter, avery.adapter_id).daily_cap == 45
    assert latest_defer_reason(avery.id) == "ramp_cap"
  end

  test "capacity reset clears today's pool send pressure and restores seeded caps", %{rows: rows} do
    avery = row!(rows, "Avery")
    eli = row!(rows, "Eli")
    dispatch_first_step!(avery.id)
    dispatch_first_step!(eli.id)

    assert :ok = Simulators.trigger(avery.id, :ramp_cap)
    assert :ok = Simulators.trigger(eli.id, :hard_bounce)
    assert Repo.get!(ChannelAdapter, avery.adapter_id).daily_cap == 45
    assert pool_member!(avery.adapter_id).sent_today > 0
    assert demo_suppression_exists?("eli@runway.example")

    assert {:ok, %{sent_events: sent_events, outcome_events: outcome_events, adapters: 3}} =
             Outbound.reset_capacity_today()

    assert sent_events > 0
    assert outcome_events > 0
    assert Repo.get!(ChannelAdapter, avery.adapter_id).daily_cap == 45
    assert pool_member!(avery.adapter_id).sent_today == 0
    refute demo_suppression_exists?("eli@runway.example")
  end

  test "rest pinned sender marks the adapter resting and lets pool failover dispatch", %{
    rows: rows
  } do
    quinn = row!(rows, "Quinn")
    dispatch_first_step!(quinn.id)

    original_adapter_id = quinn.adapter_id

    assert :ok = Simulators.trigger(quinn.id, :rest_pinned_sender)

    assert Repo.get!(ChannelAdapter, original_adapter_id).health_state == :resting
    refute Repo.get!(Enrollment, quinn.id).adapter_id == original_adapter_id
  end

  defp row!(rows, first_name),
    do: Enum.find(rows, &(&1.first_name == first_name)) || flunk("missing #{first_name}")

  defp pool_member!(adapter_id) do
    Outbound.list_pool_members()
    |> Enum.find(&(&1.id == adapter_id))
    |> case do
      nil -> flunk("missing pool member #{adapter_id}")
      member -> member
    end
  end

  defp demo_suppression_exists?(recipient) do
    Repo.exists?(
      from(suppression in Suppression,
        where: suppression.tenant_key == "demo",
        where: suppression.recipient_normalized == ^recipient,
        where: suppression.source == "demo-button"
      )
    )
  end

  defp dispatch_first_step!(enrollment_id) do
    execution =
      Repo.one!(
        from(execution in StepExecution,
          where: execution.enrollment_id == ^enrollment_id,
          order_by: [asc: execution.scheduled_for, asc: execution.inserted_at],
          limit: 1
        )
      )

    assert :ok = DispatchStep.perform(%{step_execution_id: execution.id})
  end

  defp latest_defer_reason(enrollment_id) do
    enrollment_id
    |> Outbound.latest_defer()
    |> Map.fetch!("reason")
  end
end
