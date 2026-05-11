defmodule DripdropDemo.Scenarios.Outbound.Simulators do
  @moduledoc """
  Operator-triggered outcome simulators for the outbound campaigns demo.
  """

  import Ecto.Query

  alias DripDrop.{ChannelAdapter, Enrollment, MessageEvent, StepExecution}
  alias DripDrop.Jobs.DispatchStep
  alias DripdropDemo.Repo
  alias DripdropDemo.Scenarios.Outbound
  alias DripdropDemo.Scenarios.Outbound.Outcomes

  @type outcome :: Outcomes.outcome()
  @type adapter_state :: :active | :resting | :probing | :ramping

  # Operator-triggered rest auto-recovers within the demo session so an
  # operator who clicks "Rest" can flip the sender back later.
  @operator_rest_seconds 60

  # Scripted rebind scenario uses a long rest so the pool failover stays
  # visible until the demo is reset; otherwise auto-recovery would re-pin.
  @scenario_rest_seconds 8 * 86_400

  @doc "Triggers a configured outbound demo outcome for one enrollment."
  @spec trigger(String.t(), outcome()) :: :ok | {:error, term()}
  def trigger(_enrollment_id, :ghost), do: :ok

  def trigger(enrollment_id, outcome) when is_binary(enrollment_id) and is_atom(outcome) do
    with :ok <- validate_outcome(outcome),
         {:ok, enrollment} <- fetch_enrollment(enrollment_id) do
      case outcome do
        :reply_positive -> positive_reply(enrollment)
        :reply_ooo -> reply(enrollment, :ooo)
        :hard_bounce -> hard_bounce(enrollment)
        :soft_bounce -> soft_bounce(enrollment)
        :unsubscribe -> unsubscribe(enrollment)
        :ramp_cap -> ramp_cap(enrollment)
        :rest_pinned_sender -> rest_pinned_sender(enrollment)
      end
    end
  end

  defp validate_outcome(outcome) do
    if Outcomes.valid?(outcome), do: :ok, else: {:error, :unknown_outcome}
  end

  defp fetch_enrollment(enrollment_id) do
    case Repo.get(Enrollment, enrollment_id) do
      nil -> {:error, :not_found}
      enrollment -> {:ok, enrollment}
    end
  end

  @doc "Applies a demo-visible health state to a sender adapter."
  @spec set_adapter_state(String.t(), adapter_state()) :: :ok | {:error, term()}
  def set_adapter_state(adapter_id, state)
      when is_binary(adapter_id) and state in [:active, :resting, :probing, :ramping] do
    attrs = %{health_state: state, source: "demo"}

    attrs =
      if state == :resting do
        until = DateTime.add(DateTime.utc_now(:second), @operator_rest_seconds, :second)
        Map.put(attrs, :resting_until, until)
      else
        Map.put(attrs, :resting_until, nil)
      end

    case DripDrop.set_adapter_health(adapter_id, attrs) do
      {:ok, _adapter} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Tightens a sender daily cap for the ramp-cap demo."
  @spec tighten_daily_cap(String.t(), pos_integer()) :: :ok | {:error, term()}
  def tighten_daily_cap(adapter_id, cap)
      when is_binary(adapter_id) and is_integer(cap) and cap > 0 do
    adapter = Repo.get!(ChannelAdapter, adapter_id)

    adapter
    |> ChannelAdapter.changeset(%{daily_cap: cap})
    |> Repo.update()
    |> case do
      {:ok, _adapter} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp reply(%Enrollment{} = enrollment, kind) when kind in [:positive, :ooo] do
    with %StepExecution{} = execution <-
           latest_sent_execution(enrollment.id) || {:error, :no_sent_step},
         adapter_id when is_binary(adapter_id) <-
           enrollment.adapter_id || {:error, :no_adapter_pin} do
      DripDrop.ingest_inbound_message(adapter_id, reply_message(enrollment, execution, kind))
    end
  end

  # Step 1 (consulting-intro) has no `reply_behavior: "pause_enrollment"` in
  # the seeded sequence (only steps 2 and 3 do), so DripDrop's OnReply default
  # is a no-op when a reply lands on step 1. We manually pause here so the
  # demo visibly stops sending after a positive reply lands on the first send.
  defp positive_reply(%Enrollment{} = enrollment) do
    with :ok <- reply(enrollment, :positive),
         %Enrollment{state: "active"} <- Repo.get(Enrollment, enrollment.id),
         {:ok, _enrollment} <- DripDrop.pause_enrollment(enrollment.id, enrollment.tenant_key) do
      :ok
    else
      %Enrollment{} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp reply_message(enrollment, execution, :positive) do
    %{
      message_id: "demo-positive-#{enrollment.id}@reply.dripdrop.dev",
      in_reply_to: execution.out_message_id,
      references: references_for(enrollment.id),
      from: email_for(enrollment),
      to: sender_for(execution),
      subject: "Re: Phoenix and LiveView help for #{company_for(enrollment)}",
      body_text: "This is relevant. Can you send a few times next week?",
      received_at: DateTime.utc_now(:second),
      intent: :reply,
      intent_data: %{sentiment: "positive", demo: true}
    }
  end

  defp reply_message(enrollment, execution, :ooo) do
    %{
      message_id: "demo-ooo-#{enrollment.id}@reply.dripdrop.dev",
      in_reply_to: execution.out_message_id,
      references: references_for(enrollment.id),
      from: email_for(enrollment),
      to: sender_for(execution),
      subject: "Automatic reply: out of office",
      body_text: "I am out today but will be back shortly.",
      received_at: DateTime.utc_now(:second),
      intent: :ooo,
      intent_data: %{return_at: Date.utc_today(), demo: true}
    }
  end

  defp hard_bounce(%Enrollment{} = enrollment) do
    with {:ok, _event} <- bounce(enrollment, "permanent", "mailbox_not_found"),
         {:ok, _suppression} <-
           DripDrop.suppress(%{
             tenant_key: enrollment.tenant_key,
             channel: "email",
             recipient: email_for(enrollment),
             reason: :bounce,
             source: "demo-button",
             metadata: %{outcome: "hard_bounce"}
           }) do
      :ok
    end
  end

  defp soft_bounce(%Enrollment{} = enrollment) do
    case bounce(enrollment, "temporary", "mailbox_temporarily_unavailable") do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp bounce(%Enrollment{} = enrollment, severity, reason) do
    execution = latest_sent_execution(enrollment.id) || first_execution(enrollment.id)

    %MessageEvent{}
    |> MessageEvent.changeset(%{
      step_execution_id: execution && execution.id,
      adapter_id: enrollment.adapter_id,
      tenant_key: enrollment.tenant_key,
      channel: "email",
      provider: "demo",
      provider_message_id: execution && execution.provider_message_id,
      provider_event_id: "demo-#{severity}-bounce-#{enrollment.id}",
      event_type: "bounced",
      event_data: %{
        "severity" => severity,
        "reason" => reason,
        "recipient" => email_for(enrollment),
        "demo" => true
      },
      occurred_at: DateTime.utc_now(:second)
    })
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target:
        {:unsafe_fragment, "(provider, provider_event_id) WHERE provider_event_id IS NOT NULL"}
    )
  end

  defp unsubscribe(%Enrollment{} = enrollment) do
    with {:ok, _event} <- unsubscribe_event(enrollment),
         {:ok, _suppression} <-
           DripDrop.suppress(%{
             tenant_key: enrollment.tenant_key,
             channel: "email",
             recipient: email_for(enrollment),
             reason: :unsubscribe,
             source: "demo-button",
             metadata: %{outcome: "unsubscribe"}
           }) do
      :ok
    end
  end

  defp unsubscribe_event(enrollment) do
    execution = latest_sent_execution(enrollment.id) || first_execution(enrollment.id)

    %MessageEvent{}
    |> MessageEvent.changeset(%{
      step_execution_id: execution && execution.id,
      adapter_id: enrollment.adapter_id,
      tenant_key: enrollment.tenant_key,
      channel: "email",
      provider: "demo",
      provider_event_id: "demo-unsubscribe-#{enrollment.id}",
      event_type: "unsubscribed",
      event_data: %{"recipient" => email_for(enrollment), "demo" => true},
      occurred_at: DateTime.utc_now(:second)
    })
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target:
        {:unsafe_fragment, "(provider, provider_event_id) WHERE provider_event_id IS NOT NULL"}
    )
  end

  defp ramp_cap(%Enrollment{adapter_id: adapter_id} = enrollment) when is_binary(adapter_id) do
    adapter = Repo.get!(ChannelAdapter, adapter_id)

    with :ok <- tighten_daily_cap(adapter_id, 1),
         :ok <- ensure_sent_count(enrollment, adapter_id, 1) do
      try do
        dispatch_next(enrollment.id)
      after
        restore_daily_cap(adapter_id, adapter.daily_cap)
      end
    end
  end

  defp ramp_cap(_enrollment), do: {:error, :no_adapter_pin}

  defp restore_daily_cap(adapter_id, daily_cap) do
    ChannelAdapter
    |> Repo.get!(adapter_id)
    |> ChannelAdapter.changeset(%{daily_cap: daily_cap})
    |> Repo.update!()
  end

  defp rest_pinned_sender(%Enrollment{adapter_id: adapter_id} = enrollment)
       when is_binary(adapter_id) do
    with :ok <- rest_adapter(adapter_id, @scenario_rest_seconds) do
      dispatch_next(enrollment.id)
    end
  end

  defp rest_pinned_sender(_enrollment), do: {:error, :no_adapter_pin}

  defp rest_adapter(adapter_id, seconds) do
    case DripDrop.set_adapter_health(adapter_id, %{
           health_state: :resting,
           resting_until: DateTime.add(DateTime.utc_now(:second), seconds, :second),
           source: "demo"
         }) do
      {:ok, _adapter} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch_next(enrollment_id) do
    case next_scheduled_execution(enrollment_id) do
      nil -> {:error, :no_scheduled_step}
      execution -> DispatchStep.perform(%{step_execution_id: execution.id})
    end
  end

  defp ensure_sent_count(enrollment, adapter_id, count) do
    current =
      MessageEvent
      |> where([event], event.adapter_id == ^adapter_id)
      |> where([event], event.tenant_key == ^enrollment.tenant_key)
      |> where([event], event.event_type == "sent")
      |> where([event], fragment("?::date", event.occurred_at) == ^Date.utc_today())
      |> Repo.aggregate(:count)

    missing = max(count - current, 0)

    if missing > 0 do
      Enum.each(1..missing, fn index ->
        insert_synthetic_sent(enrollment, adapter_id, index)
      end)
    end

    :ok
  end

  defp insert_synthetic_sent(enrollment, adapter_id, index) do
    %MessageEvent{}
    |> MessageEvent.changeset(%{
      adapter_id: adapter_id,
      tenant_key: enrollment.tenant_key,
      channel: "email",
      provider: "demo",
      provider_event_id: "demo-ramp-cap-sent-#{enrollment.id}-#{index}",
      event_type: "sent",
      event_data: %{"adapter_id" => adapter_id, "demo" => true},
      occurred_at: DateTime.utc_now(:second)
    })
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target:
        {:unsafe_fragment, "(provider, provider_event_id) WHERE provider_event_id IS NOT NULL"}
    )
  end

  defp latest_sent_execution(enrollment_id) do
    StepExecution
    |> where([execution], execution.enrollment_id == ^enrollment_id)
    |> where([execution], execution.state == "sent")
    |> where([execution], not is_nil(execution.out_message_id))
    |> order_by([execution], desc: execution.executed_at, desc: execution.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp first_execution(enrollment_id) do
    StepExecution
    |> where([execution], execution.enrollment_id == ^enrollment_id)
    |> order_by([execution], asc: execution.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp next_scheduled_execution(enrollment_id) do
    StepExecution
    |> where([execution], execution.enrollment_id == ^enrollment_id)
    |> where([execution], execution.state == "scheduled")
    |> order_by([execution], asc: execution.scheduled_for, asc: execution.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp references_for(enrollment_id) do
    enrollment_id
    |> Outbound.latest_thread_rows()
    |> Enum.map(& &1.out_message_id)
    |> Enum.reject(&is_nil/1)
  end

  defp sender_for(%{payload: payload}) when is_map(payload) do
    Map.get(payload, "from") || Map.get(payload, :from) || "sender@goodway.dev"
  end

  defp sender_for(_execution), do: "sender@goodway.dev"

  defp email_for(%Enrollment{data: data}) when is_map(data), do: Map.get(data, "email")
  defp email_for(_enrollment), do: nil

  defp company_for(%Enrollment{data: data}) when is_map(data),
    do: Map.get(data, "company", "your team")

  defp company_for(_enrollment), do: "your team"
end
