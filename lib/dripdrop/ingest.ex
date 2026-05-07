defmodule DripDrop.Ingest do
  @moduledoc """
  Normalizes verified provider webhooks into DripDrop message events.

  The webhook plug owns routing and signature verification. This module owns the
  provider-specific payload mapping and the database transaction that records an
  event and any resulting suppression.
  """

  import Ecto.Query

  alias DripDrop.{Clock, MessageEvent, OnReply, Redact, Repo, StepExecution, Suppressions}
  alias Ecto.Multi

  @doc """
  Normalizes and persists a verified provider webhook event.
  """
  @spec ingest(map(), map()) :: :ok | {:error, term()}
  def ingest(adapter, request) do
    with {:ok, normalized} <- normalize(adapter, request),
         {:ok, normalized} <- attach_execution(normalized),
         {:ok, _result} <- persist(normalized) do
      maybe_route_reply(normalized)
    end
  end

  defp persist(normalized) do
    Multi.new()
    |> Multi.insert(:event, MessageEvent.changeset(%MessageEvent{}, event_attrs(normalized)))
    |> maybe_suppress(normalized)
    |> Repo.transaction()
    |> case do
      {:ok, result} ->
        {:ok, result}

      {:error, :event, %Ecto.Changeset{} = changeset, _changes} ->
        if duplicate_event?(changeset) do
          emit_duplicate(normalized)
          {:ok, :duplicate}
        else
          {:error, changeset}
        end

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp event_attrs(normalized) do
    %{
      step_execution_id: normalized.step_execution_id,
      tenant_key: normalized.tenant_key,
      channel: normalized.channel,
      provider: normalized.provider,
      provider_message_id: normalized.provider_message_id,
      provider_event_id: normalized.provider_event_id,
      event_type: normalized.event_type,
      event_data: Redact.scrub(normalized.event_data),
      occurred_at: normalized.occurred_at || Clock.now()
    }
  end

  defp maybe_suppress(multi, %{event_type: "bounced", severity: "permanent"} = normalized),
    do: suppress(multi, normalized, "bounce")

  defp maybe_suppress(multi, %{event_type: "complained"} = normalized),
    do: suppress(multi, normalized, "complaint")

  defp maybe_suppress(multi, %{event_type: "unsubscribed"} = normalized),
    do: suppress(multi, normalized, "unsubscribe")

  defp maybe_suppress(multi, %{event_type: "bounced", severity: "temporary"} = normalized),
    do: increment_retry_count(multi, normalized)

  defp maybe_suppress(multi, _normalized), do: multi

  defp maybe_route_reply(%{event_type: "replied"} = normalized) do
    execution =
      case normalized.step_execution_id do
        nil -> nil
        id -> Repo.get!(StepExecution, id)
      end

    OnReply.handle_reply(normalized, execution)
  end

  defp maybe_route_reply(_normalized), do: :ok

  defp suppress(multi, normalized, reason) do
    Multi.run(multi, :suppression, fn _repo, _changes ->
      Suppressions.suppress(%{
        tenant_key: normalized.tenant_key,
        channel: normalized.channel,
        recipient: normalized.recipient,
        reason: reason,
        source: normalized.provider,
        metadata: %{provider_event_id: normalized.provider_event_id}
      })
    end)
  end

  defp increment_retry_count(multi, %{step_execution_id: nil}), do: multi

  defp increment_retry_count(multi, normalized) do
    Multi.update_all(
      multi,
      :retry_count,
      from(execution in StepExecution, where: execution.id == ^normalized.step_execution_id),
      inc: [retry_count: 1],
      set: [updated_at: Clock.now()]
    )
  end

  defp attach_execution(%{provider_message_id: nil} = normalized), do: {:ok, normalized}

  defp attach_execution(normalized) do
    StepExecution
    |> where([execution], execution.provider_message_id == ^normalized.provider_message_id)
    |> where([execution], execution.channel == ^normalized.channel)
    |> where_tenant_match(normalized.tenant_key)
    |> order_by([execution], desc: execution.inserted_at)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil ->
        emit_unmatched(normalized)
        {:ok, normalized}

      execution ->
        {:ok,
         %{
           normalized
           | step_execution_id: execution.id,
             tenant_key: execution.tenant_key || normalized.tenant_key
         }}
    end
  end

  defp where_tenant_match(query, nil),
    do: where(query, [execution], is_nil(execution.tenant_key))

  defp where_tenant_match(query, tenant_key),
    do: where(query, [execution], execution.tenant_key == ^tenant_key)

  defp emit_unmatched(normalized) do
    :telemetry.execute([:dripdrop, :ingest, :unmatched_event], %{count: 1}, %{
      provider: normalized.provider,
      provider_message_id: normalized.provider_message_id,
      provider_event_id: normalized.provider_event_id
    })
  end

  defp emit_duplicate(normalized) do
    :telemetry.execute([:dripdrop, :ingest, :duplicate], %{count: 1}, %{
      provider: normalized.provider,
      provider_event_id: normalized.provider_event_id
    })
  end

  defp duplicate_event?(%Ecto.Changeset{errors: errors}) do
    Keyword.has_key?(errors, :provider_event_id)
  end

  defp normalize(%{provider: "mailgun"} = adapter, request) do
    event = body(request)["event-data"] || %{}
    message = event["message"] || %{}
    headers = message["headers"] || %{}

    {:ok,
     base(adapter, request, %{
       event_type: event_type(event["event"]),
       provider_event_id: event["id"],
       provider_message_id: headers["message-id"],
       recipient: event["recipient"],
       occurred_at: timestamp(event["timestamp"]),
       severity: bounce_severity(event),
       event_data: body(request)
     })}
  end

  defp normalize(%{provider: "sendgrid"} = adapter, request) do
    event =
      request
      |> body()
      |> List.wrap()
      |> List.first()
      |> Kernel.||(%{})

    {:ok,
     base(adapter, request, %{
       event_type: event_type(event["event"]),
       provider_event_id: event["sg_event_id"],
       provider_message_id: event["sg_message_id"] || event["smtp-id"],
       recipient: event["email"],
       occurred_at: timestamp(event["timestamp"]),
       severity: sendgrid_bounce_severity(event),
       event_data: event
     })}
  end

  defp normalize(%{provider: "postmark"} = adapter, request) do
    event = body(request)

    {:ok,
     base(adapter, request, %{
       event_type: postmark_event_type(event["RecordType"]),
       provider_event_id: event["MessageID"],
       provider_message_id: event["MessageID"],
       recipient: event["Recipient"] || event["Email"],
       occurred_at: timestamp(event["DeliveredAt"] || event["ReceivedAt"]),
       severity: postmark_bounce_severity(event),
       event_data: event
     })}
  end

  defp normalize(%{provider: "mailersend"} = adapter, request) do
    event = body(request)
    data = event["data"] || %{}

    {:ok,
     base(adapter, request, %{
       event_type: event_type(data["type"] || event["type"]),
       provider_event_id: data["id"],
       provider_message_id: data["message_id"],
       recipient: data["email"],
       occurred_at: timestamp(event["created_at"]),
       severity: nil,
       event_data: event
     })}
  end

  defp normalize(%{provider: "ses"} = adapter, request) do
    envelope = body(request)
    message = envelope["Message"] |> decode_json()
    mail = message["mail"] || %{}
    {event_type, recipient, severity} = ses_event(message)

    {:ok,
     base(adapter, request, %{
       event_type: event_type,
       provider_event_id: envelope["MessageId"],
       provider_message_id: mail["messageId"],
       recipient: recipient,
       occurred_at: timestamp(envelope["Timestamp"]),
       severity: severity,
       event_data: envelope
     })}
  end

  defp normalize(%{provider: "twilio"} = adapter, request) do
    event = params(request)

    {:ok,
     base(adapter, request, %{
       event_type: twilio_event_type(event["MessageStatus"] || event["SmsStatus"]),
       provider_event_id: event["MessageSid"] || event["SmsSid"],
       provider_message_id: event["MessageSid"] || event["SmsSid"],
       recipient: event["To"],
       occurred_at: nil,
       severity: twilio_severity(event),
       event_data: event
     })}
  end

  defp normalize(adapter, _request), do: {:error, {:unsupported_provider, adapter.provider}}

  defp base(adapter, _request, attrs) do
    Map.merge(attrs, %{
      step_execution_id: nil,
      tenant_key: adapter.tenant_key,
      channel: adapter.channel,
      provider: adapter.provider
    })
  end

  defp body(%{body_params: body}) when is_map(body), do: body
  defp body(%{body_params: body}) when is_list(body), do: body
  defp body(%{body: body}) when is_map(body), do: body
  defp body(%{raw_body: raw_body}) when is_binary(raw_body), do: decode_json(raw_body)
  defp body(_request), do: %{}

  defp params(%{params: params}) when is_map(params), do: params
  defp params(%{form: form}) when is_map(form), do: form
  defp params(request), do: body(request)

  defp decode_json(nil), do: %{}

  defp decode_json(raw_body) when is_binary(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{}
    end
  end

  defp decode_json(body), do: body

  defp event_type("delivered"), do: "delivered"
  defp event_type("Delivery"), do: "delivered"
  defp event_type("opened"), do: "opened"
  defp event_type("open"), do: "opened"
  defp event_type("clicked"), do: "clicked"
  defp event_type("click"), do: "clicked"
  defp event_type("complained"), do: "complained"
  defp event_type("inbound"), do: "replied"
  defp event_type("replied"), do: "replied"
  defp event_type("reply"), do: "replied"
  defp event_type("spam_complaint"), do: "complained"
  defp event_type("complaint"), do: "complained"
  defp event_type("unsubscribed"), do: "unsubscribed"
  defp event_type("unsubscribe"), do: "unsubscribed"
  defp event_type("bounced"), do: "bounced"
  defp event_type("bounce"), do: "bounced"
  defp event_type("blocked"), do: "failed"
  defp event_type("deferred"), do: "failed"
  defp event_type("dropped"), do: "failed"
  defp event_type("processed"), do: "sent"
  defp event_type("activity.delivered"), do: "delivered"
  defp event_type("activity.hard_bounced"), do: "bounced"
  defp event_type("activity.soft_bounced"), do: "bounced"
  defp event_type("activity.spam_complaint"), do: "complained"
  defp event_type(_event), do: "failed"

  defp postmark_event_type("Delivery"), do: "delivered"
  defp postmark_event_type("Bounce"), do: "bounced"
  defp postmark_event_type("SpamComplaint"), do: "complained"
  defp postmark_event_type("SubscriptionChange"), do: "unsubscribed"
  defp postmark_event_type(_type), do: "failed"

  defp twilio_event_type(nil), do: "replied"
  defp twilio_event_type(status) when status in ["delivered", "sent"], do: "delivered"
  defp twilio_event_type(status) when status in ["undelivered", "failed"], do: "bounced"
  defp twilio_event_type(_status), do: "sent"

  defp ses_event(%{"notificationType" => "Delivery"} = event) do
    delivery = event["delivery"] || %{}
    {"delivered", List.first(delivery["recipients"] || []), nil}
  end

  defp ses_event(%{"notificationType" => "Bounce"} = event) do
    bounce = event["bounce"] || %{}
    recipient = bounce["bouncedRecipients"] |> List.wrap() |> List.first() || %{}
    severity = if bounce["bounceType"] == "Permanent", do: "permanent", else: "temporary"
    {"bounced", recipient["emailAddress"], severity}
  end

  defp ses_event(%{"notificationType" => "Complaint"} = event) do
    complaint = event["complaint"] || %{}
    recipient = complaint["complainedRecipients"] |> List.wrap() |> List.first() || %{}
    {"complained", recipient["emailAddress"], nil}
  end

  defp ses_event(_event), do: {"failed", nil, nil}

  defp bounce_severity(%{"severity" => "permanent"}), do: "permanent"
  defp bounce_severity(%{"severity" => "temporary"}), do: "temporary"
  defp bounce_severity(_event), do: nil

  defp sendgrid_bounce_severity(%{"event" => "bounce"}), do: "permanent"
  defp sendgrid_bounce_severity(%{"event" => "deferred"}), do: "temporary"
  defp sendgrid_bounce_severity(_event), do: nil

  defp postmark_bounce_severity(%{"Type" => "HardBounce"}), do: "permanent"
  defp postmark_bounce_severity(%{"Type" => "SoftBounce"}), do: "temporary"
  defp postmark_bounce_severity(_event), do: nil

  defp twilio_severity(%{"MessageStatus" => status}) when status in ["undelivered", "failed"],
    do: "permanent"

  defp twilio_severity(_event), do: nil

  defp timestamp(nil), do: nil

  defp timestamp(value) when is_float(value) do
    value
    |> trunc()
    |> DateTime.from_unix!()
    |> DateTime.to_naive()
  end

  defp timestamp(value) when is_integer(value) do
    value
    |> DateTime.from_unix!()
    |> DateTime.to_naive()
  end

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_naive(datetime)
      _invalid -> nil
    end
  end
end
