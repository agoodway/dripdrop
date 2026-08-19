defmodule DripDrop.Integration.FullStackTest do
  use DripDrop.IntegrationCase

  @moduletag :integration

  alias DripDrop.{
    MessageEvent,
    StepExecution,
    Suppression,
    TestRepo
  }

  alias DripDrop.TestSupport.Integration.Scenarios
  alias DripDrop.TestSupport.PgflowHarness
  alias DripDrop.Web.WebhookPlug

  setup_all do
    previous_scheduler = Application.get_env(:dripdrop, :scheduler)
    previous_stale_after = Application.get_env(:dripdrop, :dispatch_stale_after_seconds)

    Application.put_env(:dripdrop, :scheduler, DripDrop.Schedulers.Pgflow)
    Application.put_env(:dripdrop, :dispatch_stale_after_seconds, 5)

    on_exit(fn ->
      Application.put_env(:dripdrop, :scheduler, previous_scheduler)
      Application.put_env(:dripdrop, :dispatch_stale_after_seconds, previous_stale_after)
    end)

    :ok
  end

  test "enrollment dispatches through PgFlow, records sent event, and ingests delivery webhook" do
    Req.Test.set_req_test_to_shared()
    on_exit(&Req.Test.set_req_test_to_private/0)

    req_name = stub_mailgun()
    previous_req_options = Application.get_env(:dripdrop, :channel_req_options)
    Application.put_env(:dripdrop, :channel_req_options, plug: {Req.Test, req_name})

    on_exit(fn ->
      Application.put_env(:dripdrop, :channel_req_options, previous_req_options)
    end)

    start_supervised!(PgflowHarness.child_spec())

    scenario = Scenarios.email_full_scenario()

    assert {:ok, enrollment} = DripDrop.enroll(scenario.enroll_attrs)
    assert :ok = PgflowHarness.wait_for_idle()

    welcome_execution =
      eventually(fn ->
        execution = step_execution!(enrollment.id, scenario.step.id)
        assert execution.state == "sent"
        assert execution.provider_message_id
        execution
      end)

    assert TestRepo.exists?(
             from(event in MessageEvent,
               where:
                 event.step_execution_id == ^welcome_execution.id and event.event_type == "sent"
             )
           )

    conn =
      :post
      |> Plug.Test.conn(
        "/mailgun/#{scenario.adapter.id}",
        Jason.encode!(
          signed_mailgun_body(
            "delivered",
            "evt-delivered",
            welcome_execution.provider_message_id,
            scenario.recipient
          )
        )
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> WebhookPlug.call([])

    assert conn.status == 202

    assert TestRepo.exists?(
             from(event in MessageEvent,
               where:
                 event.step_execution_id == ^welcome_execution.id and
                   event.event_type == "delivered"
             )
           )

    follow_up_execution = step_execution!(enrollment.id, scenario.next_step.id)
    assert follow_up_execution.state in ["scheduled", "claiming", "sending", "sent"]
  end

  test "hard bounce suppresses recipient before follow-up dispatch is skipped" do
    Req.Test.set_req_test_to_shared()
    on_exit(&Req.Test.set_req_test_to_private/0)

    req_name = stub_mailgun()
    previous_req_options = Application.get_env(:dripdrop, :channel_req_options)
    Application.put_env(:dripdrop, :channel_req_options, plug: {Req.Test, req_name})

    on_exit(fn ->
      Application.put_env(:dripdrop, :channel_req_options, previous_req_options)
    end)

    start_supervised!(
      PgflowHarness.child_spec(
        min_poll_interval: 500,
        max_poll_interval: 500,
        notify_fallback_interval: 500
      )
    )

    scenario =
      Scenarios.email_full_scenario(
        next_step_timing: %{type: "delay", delay_amount: 2, delay_unit: "seconds"}
      )

    assert {:ok, enrollment} = DripDrop.enroll(scenario.enroll_attrs)

    welcome_execution =
      eventually(fn ->
        execution = step_execution!(enrollment.id, scenario.step.id)
        assert execution.state == "sent"
        assert execution.provider_message_id
        execution
      end)

    conn =
      :post
      |> Plug.Test.conn(
        "/mailgun/#{scenario.adapter.id}",
        Jason.encode!(
          signed_mailgun_body(
            "bounced",
            "evt-hard-bounce",
            welcome_execution.provider_message_id,
            scenario.recipient,
            %{"severity" => "permanent"}
          )
        )
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> WebhookPlug.call([])

    assert conn.status == 202

    suppression = TestRepo.one!(Suppression)
    assert suppression.reason == "bounce"
    assert suppression.recipient_normalized == "sam@example.com"

    follow_up_execution =
      eventually(fn ->
        execution = step_execution!(enrollment.id, scenario.next_step.id)
        assert execution.state == "skipped"
        execution
      end)

    assert TestRepo.exists?(
             from(event in MessageEvent,
               where:
                 event.step_execution_id == ^follow_up_execution.id and
                   event.event_type == "skipped"
             )
           )
  end

  test "pre-suppressed recipient skips dispatch without provider HTTP call" do
    Req.Test.set_req_test_to_shared()
    on_exit(&Req.Test.set_req_test_to_private/0)

    req_name = stub_forbidden_mailgun()
    previous_req_options = Application.get_env(:dripdrop, :channel_req_options)
    Application.put_env(:dripdrop, :channel_req_options, plug: {Req.Test, req_name})

    on_exit(fn ->
      Application.put_env(:dripdrop, :channel_req_options, previous_req_options)
    end)

    attach_telemetry([:dripdrop, :policy, :suppressed])
    start_supervised!(PgflowHarness.child_spec())

    scenario = Scenarios.email_full_scenario()

    assert {:ok, _suppression} =
             DripDrop.Suppressions.suppress(%{
               tenant_key: "tenant-a",
               channel: "email",
               recipient: scenario.recipient,
               reason: "manual",
               source: "test"
             })

    assert {:ok, enrollment} = DripDrop.enroll(scenario.enroll_attrs)
    assert :ok = PgflowHarness.wait_for_idle()

    execution =
      eventually(fn ->
        execution = step_execution!(enrollment.id, scenario.step.id)
        assert execution.state == "skipped"
        execution
      end)

    assert TestRepo.exists?(
             from(event in MessageEvent,
               where: event.step_execution_id == ^execution.id and event.event_type == "skipped"
             )
           )

    assert_receive {:telemetry, [:dripdrop, :policy, :suppressed], %{count: 1},
                    %{channel: "email", tenant_key: "tenant-a"}}
  end

  test "HTTP hook result renders into email payload before adapter delivery" do
    Req.Test.set_req_test_to_shared()
    on_exit(&Req.Test.set_req_test_to_private/0)

    req_name = stub_mailgun_with_http_hook()
    previous_channel_req_options = Application.get_env(:dripdrop, :channel_req_options)
    previous_hook_req_options = Application.get_env(:dripdrop, :http_hook_req_options)

    Application.put_env(:dripdrop, :channel_req_options, plug: {Req.Test, req_name})
    Application.put_env(:dripdrop, :http_hook_req_options, plug: {Req.Test, req_name})

    on_exit(fn ->
      Application.put_env(:dripdrop, :channel_req_options, previous_channel_req_options)
      Application.put_env(:dripdrop, :http_hook_req_options, previous_hook_req_options)
    end)

    start_supervised!(PgflowHarness.child_spec())

    scenario = Scenarios.email_http_hook_scenario()

    assert {:ok, enrollment} = DripDrop.enroll(scenario.enroll_attrs)
    assert :ok = PgflowHarness.wait_for_idle()

    execution =
      eventually(fn ->
        execution = step_execution!(enrollment.id, scenario.step.id)
        assert execution.state == "sent"
        execution
      end)

    assert execution.payload["text"] == "Eligibility: approved"
  end

  defp step_execution!(enrollment_id, step_id) do
    TestRepo.one!(
      from(execution in StepExecution,
        where: execution.enrollment_id == ^enrollment_id and execution.step_id == ^step_id
      )
    )
  end

  defp stub_mailgun do
    name = :"full-stack-mailgun-#{System.unique_integer([:positive])}"

    Req.Test.stub(name, fn conn ->
      assert conn.request_path == "/v3/mg.example.com/messages"
      body = form_body(conn)

      assert body["to"] == "sam@example.com"
      assert body["subject"] in ["Welcome Sam", "Next step"]
      assert body["text"] in ["Hello Sam", "Next step"]

      Req.Test.json(conn, %{
        "id" => "mg-msg-#{System.unique_integer([:positive])}",
        "message" => "Queued. Thank you."
      })
    end)

    name
  end

  defp stub_forbidden_mailgun do
    name = :"forbidden-mailgun-#{System.unique_integer([:positive])}"

    Req.Test.stub(name, fn _conn ->
      flunk("provider HTTP call should not happen for a suppressed recipient")
    end)

    name
  end

  defp stub_mailgun_with_http_hook do
    name = :"full-stack-hook-#{System.unique_integer([:positive])}"

    Req.Test.stub(name, fn conn ->
      case conn.request_path do
        "/eligibility/subscriber-" <> _rest ->
          assert raw_body(conn) == ~s({"email": "sam@example.com"})
          Req.Test.json(conn, %{"status" => "approved"})

        "/v3/mg.example.com/messages" ->
          body = form_body(conn)

          assert body["to"] == "sam@example.com"
          assert body["text"] in ["Eligibility: approved", "Next step"]

          Req.Test.json(conn, %{
            "id" => "mg-msg-#{System.unique_integer([:positive])}",
            "message" => "Queued. Thank you."
          })
      end
    end)

    name
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

  defp form_body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    URI.decode_query(body)
  end

  defp raw_body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    body
  end

  defp signed_mailgun_body(event, event_id, message_id, recipient, attrs \\ %{}) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix() |> Integer.to_string()
    token = "token"

    signature =
      :hmac
      |> :crypto.mac(:sha256, "signing-key", "#{timestamp}#{token}")
      |> Base.encode16(case: :lower)

    %{
      "signature" => %{
        "timestamp" => timestamp,
        "token" => token,
        "signature" => signature
      },
      "event-data" =>
        Map.merge(
          %{
            "id" => event_id,
            "event" => event,
            "recipient" => recipient,
            "timestamp" => DateTime.utc_now() |> DateTime.to_unix(),
            "message" => %{"headers" => %{"message-id" => message_id}}
          },
          attrs
        )
    }
  end
end
