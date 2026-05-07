defmodule DripDrop.IngestTest do
  use DripDrop.DataCase, async: false

  alias DripDrop.{Enrollment, Fixtures, MessageEvent, StepExecution, Suppression, TestRepo}
  alias DripDrop.Web.WebhookPlug

  defmodule WebhookRouter do
    @moduledoc """
    Minimal Plug router used to assert DripDrop's mount macro.
    """

    use Plug.Router

    import DripDrop.Web.Router

    plug(:match)
    plug(:dispatch)

    dripdrop_webhooks("/webhooks/dripdrop")
  end

  describe "message event persistence" do
    test "persists delivered events and links by provider message id" do
      %{adapter: adapter, execution: execution} = delivery_context("msg-delivered")

      assert :ok =
               DripDrop.Ingest.ingest(
                 adapter,
                 mailgun_request("delivered", "evt-delivered", "msg-delivered")
               )

      event = TestRepo.one!(MessageEvent)
      assert event.event_type == "delivered"
      assert event.step_execution_id == execution.id
      assert event.provider_message_id == "msg-delivered"
    end

    test "persists unmatched events and emits telemetry" do
      attach_telemetry([:dripdrop, :ingest, :unmatched_event])
      adapter = mailgun_adapter()

      assert :ok =
               DripDrop.Ingest.ingest(
                 adapter,
                 mailgun_request("delivered", "evt-unmatched", "missing-msg")
               )

      event = TestRepo.one!(MessageEvent)
      assert is_nil(event.step_execution_id)

      assert_receive {:telemetry, [:dripdrop, :ingest, :unmatched_event], %{count: 1},
                      %{provider: "mailgun", provider_message_id: "missing-msg"}}
    end

    test "duplicate provider events are 200-style no-ops and emit telemetry" do
      attach_telemetry([:dripdrop, :ingest, :duplicate])
      %{adapter: adapter} = delivery_context("msg-duplicate")
      request = mailgun_request("delivered", "evt-duplicate", "msg-duplicate")

      assert :ok = DripDrop.Ingest.ingest(adapter, request)
      assert :ok = DripDrop.Ingest.ingest(adapter, request)

      assert TestRepo.aggregate(MessageEvent, :count) == 1

      assert_receive {:telemetry, [:dripdrop, :ingest, :duplicate], %{count: 1},
                      %{provider: "mailgun"}}
    end
  end

  describe "suppression and reply effects" do
    test "hard bounce inserts the event and upserts a suppression atomically" do
      %{adapter: adapter} = delivery_context("msg-hard-bounce")

      assert :ok =
               DripDrop.Ingest.ingest(
                 adapter,
                 mailgun_request("bounced", "evt-hard-bounce", "msg-hard-bounce", %{
                   "severity" => "permanent"
                 })
               )

      assert TestRepo.one!(MessageEvent).event_type == "bounced"
      suppression = TestRepo.one!(Suppression)
      assert suppression.reason == "bounce"
      assert suppression.recipient_normalized == "ada@example.com"
    end

    test "soft bounce does not suppress and increments retry count" do
      %{adapter: adapter, execution: execution} = delivery_context("msg-soft-bounce")

      assert :ok =
               DripDrop.Ingest.ingest(
                 adapter,
                 mailgun_request("bounced", "evt-soft-bounce", "msg-soft-bounce", %{
                   "severity" => "temporary"
                 })
               )

      assert TestRepo.aggregate(Suppression, :count) == 0
      assert TestRepo.get!(StepExecution, execution.id).retry_count == execution.retry_count + 1
    end

    test "reply behavior pauses enrollment only when configured" do
      %{adapter: adapter, enrollment: paused_enrollment} =
        delivery_context("msg-reply-pause",
          step_config: %{"reply_behavior" => "pause_enrollment"}
        )

      assert :ok =
               DripDrop.Ingest.ingest(
                 adapter,
                 mailgun_request("inbound", "evt-reply-pause", "msg-reply-pause")
               )

      assert TestRepo.get!(Enrollment, paused_enrollment.id).state == "paused"

      %{adapter: adapter, enrollment: active_enrollment} = delivery_context("msg-reply-info")

      assert :ok =
               DripDrop.Ingest.ingest(
                 adapter,
                 mailgun_request("inbound", "evt-reply-info", "msg-reply-info")
               )

      assert TestRepo.get!(Enrollment, active_enrollment.id).state == "active"
    end
  end

  describe "webhook plug" do
    test "router macro mounts provider webhooks under the configured base path" do
      %{adapter: adapter} = delivery_context("msg-mounted")
      body = mailgun_body("delivered", "evt-mounted", "msg-mounted")

      conn =
        :post
        |> Plug.Test.conn(
          "/webhooks/dripdrop/mailgun/#{adapter.id}",
          Jason.encode!(signed_mailgun_body(body))
        )
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> WebhookRouter.call([])

      assert conn.status == 202
      assert TestRepo.one!(MessageEvent).provider_event_id == "evt-mounted"
    end

    test "valid Mailgun signatures are accepted and persisted" do
      %{adapter: adapter} = delivery_context("msg-valid-signature")
      body = mailgun_body("delivered", "evt-valid-signature", "msg-valid-signature")

      conn =
        :post
        |> Plug.Test.conn("/mailgun/#{adapter.id}", Jason.encode!(signed_mailgun_body(body)))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> WebhookPlug.call([])

      assert conn.status == 202
      assert TestRepo.one!(MessageEvent).provider_event_id == "evt-valid-signature"
    end

    test "invalid signatures return 401 without writing events" do
      attach_telemetry([:dripdrop, :ingest, :signature_failure])
      adapter = mailgun_adapter()
      body = Jason.encode!(mailgun_body("delivered", "evt-invalid", "msg-invalid"))

      conn =
        :post
        |> Plug.Test.conn("/mailgun/#{adapter.id}", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> WebhookPlug.call([])

      assert conn.status == 401
      assert TestRepo.aggregate(MessageEvent, :count) == 0

      assert_receive {:telemetry, [:dripdrop, :ingest, :signature_failure], %{count: 1},
                      %{provider: "mailgun"}}
    end

    test "unsupported webhook providers return 404" do
      adapter = Fixtures.channel_adapter_fixture(%{provider: "smtp"})

      conn =
        :post
        |> Plug.Test.conn("/smtp/#{adapter.id}", "")
        |> WebhookPlug.call([])

      assert conn.status == 404
    end

    test "Mailgun rejects replays outside the configured skew window" do
      adapter = mailgun_adapter()
      body = mailgun_body("delivered", "evt-replay", "msg-replay")
      stale_timestamp = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.to_unix()

      signed_body = signed_mailgun_body(body, Integer.to_string(stale_timestamp))

      conn =
        :post
        |> Plug.Test.conn("/mailgun/#{adapter.id}", Jason.encode!(signed_body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> WebhookPlug.call([])

      assert conn.status == 401
      assert TestRepo.aggregate(MessageEvent, :count) == 0
    end

    test "webhook plug returns 413 when the body exceeds the configured cap" do
      previous = Application.get_env(:dripdrop, :webhook_max_body_bytes)
      Application.put_env(:dripdrop, :webhook_max_body_bytes, 256)
      on_exit(fn -> Application.put_env(:dripdrop, :webhook_max_body_bytes, previous) end)

      adapter = mailgun_adapter()
      oversized = String.duplicate("x", 1024)

      conn =
        :post
        |> Plug.Test.conn("/mailgun/#{adapter.id}", oversized)
        |> Plug.Conn.put_req_header("content-type", "application/octet-stream")
        |> WebhookPlug.call([])

      assert conn.status == 413
    end
  end

  defp delivery_context(provider_message_id, opts \\ []) do
    sequence = Fixtures.sequence_fixture()
    version = Fixtures.sequence_version_fixture(sequence)
    step = Fixtures.step_fixture(version, %{config: Keyword.get(opts, :step_config, %{})})
    enrollment = Fixtures.enrollment_fixture(sequence, version)

    execution =
      enrollment
      |> Fixtures.step_execution_fixture(step)
      |> StepExecution.changeset(%{provider_message_id: provider_message_id})
      |> TestRepo.update!()

    %{adapter: mailgun_adapter(), enrollment: enrollment, execution: execution}
  end

  defp mailgun_adapter do
    Fixtures.channel_adapter_fixture(%{
      provider: "mailgun",
      credentials: %{"api_key" => "secret", "domain" => "mg.example.com"}
    })
  end

  defp mailgun_request(event, event_id, message_id, attrs \\ %{}) do
    %{body_params: mailgun_body(event, event_id, message_id, attrs)}
  end

  defp mailgun_body(event, event_id, message_id, attrs \\ %{}) do
    event_data =
      Map.merge(
        %{
          "id" => event_id,
          "event" => event,
          "recipient" => "ada@example.com",
          "timestamp" => 1_777_777_777,
          "message" => %{"headers" => %{"message-id" => message_id}}
        },
        attrs
      )

    %{"event-data" => event_data}
  end

  defp signed_mailgun_body(body, timestamp \\ nil) do
    timestamp = timestamp || DateTime.utc_now() |> DateTime.to_unix() |> Integer.to_string()
    token = "token"

    signature =
      :hmac
      |> :crypto.mac(:sha256, "secret", "#{timestamp}#{token}")
      |> Base.encode16(case: :lower)

    Map.put(body, "signature", %{
      "timestamp" => timestamp,
      "token" => token,
      "signature" => signature
    })
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
