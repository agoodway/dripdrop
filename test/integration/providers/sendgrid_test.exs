defmodule DripDrop.Integration.Providers.SendGridTest do
  use DripDrop.DataCase, async: false

  @moduletag :integration

  alias DripDrop.{ChannelAdapter, Enrollment, Fixtures, MessageEvent, Step, TestRepo}
  alias DripDrop.Channels.Email.SendGrid
  alias DripDrop.Web.WebhookPlug

  test "posts SendGrid Mail Send v3 JSON shape with bearer auth" do
    stub_req(fn conn ->
      assert conn.request_path == "/v3/mail/send"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sg-secret"]

      body = json_body(conn)
      assert body["from"] == %{"email" => "team@example.com"}

      assert [%{"to" => [%{"email" => "ada@example.com"}]}] = body["personalizations"]
      assert body["subject"] == "Welcome"

      assert %{"type" => "text/plain", "value" => "Hello from SendGrid"} in body["content"]

      conn
      |> Plug.Conn.put_resp_header("x-message-id", "sg-msg-1")
      |> Plug.Conn.send_resp(202, "")
    end)

    assert {:ok, %{provider_message_id: "sg-msg-1"}} =
             SendGrid.deliver(
               email_step(%{text: "Hello from SendGrid"}),
               enrollment(),
               adapter_struct()
             )
  end

  test "accepts valid Event Webhook signature and rejects tampered body" do
    %{public_key: public_key, private_key: private_key} = ecdsa_key_pair()

    adapter =
      Fixtures.channel_adapter_fixture(%{
        provider: "sendgrid",
        credentials: %{
          "api_key" => "sg-secret",
          "webhook_public_key" => Base.encode64(public_key)
        }
      })

    raw_body =
      Jason.encode!([
        %{
          "email" => "ada@example.com",
          "event" => "delivered",
          "sg_event_id" => "evt-valid",
          "sg_message_id" => "sg-msg-1",
          "timestamp" => DateTime.utc_now() |> DateTime.to_unix()
        }
      ])

    timestamp = DateTime.utc_now() |> DateTime.to_unix() |> Integer.to_string()
    signature = sendgrid_signature(timestamp, raw_body, private_key)

    conn =
      :post
      |> Plug.Test.conn("/sendgrid/#{adapter.id}", raw_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-twilio-email-event-webhook-timestamp", timestamp)
      |> Plug.Conn.put_req_header("x-twilio-email-event-webhook-signature", signature)
      |> WebhookPlug.call([])

    assert conn.status == 202
    assert TestRepo.one!(MessageEvent).provider_event_id == "evt-valid"

    tampered_body = String.replace(raw_body, "evt-valid", "evt-tampered")

    conn =
      :post
      |> Plug.Test.conn("/sendgrid/#{adapter.id}", tampered_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-twilio-email-event-webhook-timestamp", timestamp)
      |> Plug.Conn.put_req_header("x-twilio-email-event-webhook-signature", signature)
      |> WebhookPlug.call([])

    assert conn.status == 401
    assert TestRepo.aggregate(MessageEvent, :count) == 1
  end

  defp adapter_struct do
    struct!(ChannelAdapter, %{
      id: Ecto.UUID.generate(),
      name: "SendGrid",
      tenant_key: "tenant-a",
      channel: "email",
      provider: "sendgrid",
      credentials: %{"api_key" => "sg-secret"},
      config: %{},
      active: true
    })
  end

  defp email_step(attrs) do
    payload =
      Map.merge(
        %{
          from: "team@example.com",
          to: "ada@example.com",
          subject: "Welcome",
          text: "Hello"
        },
        attrs
      )

    struct!(Step, %{
      channel: "email",
      key: "email-step",
      config: %{"payload" => payload},
      template_content: %{}
    })
  end

  defp enrollment do
    struct!(Enrollment, %{
      tenant_key: "tenant-a",
      subscriber_type: "user",
      subscriber_id: "ada",
      data: %{"email" => "ada@example.com"}
    })
  end

  defp ecdsa_key_pair do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :prime256v1)
    %{public_key: public_key, private_key: private_key}
  end

  defp sendgrid_signature(timestamp, raw_body, private_key) do
    :ecdsa
    |> :crypto.sign(:sha256, "#{timestamp}#{raw_body}", [private_key, :secp256r1])
    |> Base.encode64()
  end

  defp stub_req(fun) do
    previous = Application.get_env(:dripdrop, :channel_req_options)
    name = :"sendgrid-provider-#{System.unique_integer([:positive])}"

    Req.Test.stub(name, fun)
    Application.put_env(:dripdrop, :channel_req_options, plug: {Req.Test, name})
    on_exit(fn -> Application.put_env(:dripdrop, :channel_req_options, previous) end)
  end

  defp json_body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(body)
  end
end
