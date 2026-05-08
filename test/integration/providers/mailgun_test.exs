defmodule DripDrop.Integration.Providers.MailgunTest do
  use DripDrop.DataCase, async: false

  @moduletag :integration

  alias DripDrop.{ChannelAdapter, Enrollment, Fixtures, MessageEvent, Step, TestRepo}
  alias DripDrop.Channels.Email.Mailgun
  alias DripDrop.Web.WebhookPlug

  test "posts Mailgun Messages API form shape with basic auth" do
    stub_req(fn conn ->
      assert conn.request_path == "/v3/mg.example.com/messages"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Basic YXBpOnNlY3JldA=="]

      assert form_body(conn) == %{
               "from" => "team@example.com",
               "subject" => "Welcome",
               "text" => "Hello from Mailgun",
               "to" => "ada@example.com"
             }

      Req.Test.json(conn, %{"id" => "mg-msg-1", "message" => "Queued. Thank you."})
    end)

    assert {:ok, %{provider_message_id: "mg-msg-1"}} =
             Mailgun.deliver(
               email_step(%{text: "Hello from Mailgun"}),
               enrollment(),
               adapter_struct()
             )
  end

  test "accepts valid signed webhook and rejects tampered signature" do
    adapter =
      Fixtures.channel_adapter_fixture(%{
        provider: "mailgun",
        credentials: %{
          "api_key" => "secret",
          "domain" => "mg.example.com",
          "webhook_signing_key" => "webhook-secret"
        }
      })

    body = signed_mailgun_body(mailgun_body("delivered", "evt-valid", "mg-msg-1"))

    conn =
      :post
      |> Plug.Test.conn("/mailgun/#{adapter.id}", Jason.encode!(body))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> WebhookPlug.call([])

    assert conn.status == 202
    assert TestRepo.one!(MessageEvent).provider_event_id == "evt-valid"

    tampered = put_in(body, ["signature", "signature"], "invalid")

    conn =
      :post
      |> Plug.Test.conn("/mailgun/#{adapter.id}", Jason.encode!(tampered))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> WebhookPlug.call([])

    assert conn.status == 401
    assert TestRepo.aggregate(MessageEvent, :count) == 1
  end

  defp adapter_struct do
    struct!(ChannelAdapter, %{
      id: Ecto.UUID.generate(),
      name: "Mailgun",
      tenant_key: "tenant-a",
      channel: "email",
      provider: "mailgun",
      credentials: %{"api_key" => "secret", "domain" => "mg.example.com"},
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

  defp mailgun_body(event, event_id, message_id) do
    %{
      "event-data" => %{
        "id" => event_id,
        "event" => event,
        "recipient" => "ada@example.com",
        "timestamp" => DateTime.utc_now() |> DateTime.to_unix(),
        "message" => %{"headers" => %{"message-id" => message_id}}
      }
    }
  end

  defp signed_mailgun_body(body) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix() |> Integer.to_string()
    token = "token"

    signature =
      :hmac
      |> :crypto.mac(:sha256, "webhook-secret", "#{timestamp}#{token}")
      |> Base.encode16(case: :lower)

    Map.put(body, "signature", %{
      "timestamp" => timestamp,
      "token" => token,
      "signature" => signature
    })
  end

  defp stub_req(fun) do
    previous = Application.get_env(:dripdrop, :channel_req_options)
    name = :"mailgun-provider-#{System.unique_integer([:positive])}"

    Req.Test.stub(name, fun)
    Application.put_env(:dripdrop, :channel_req_options, plug: {Req.Test, name})
    on_exit(fn -> Application.put_env(:dripdrop, :channel_req_options, previous) end)
  end

  defp form_body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    URI.decode_query(body)
  end
end
