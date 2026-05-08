defmodule DripDrop.Integration.Providers.TwilioTest do
  use DripDrop.DataCase, async: false

  @moduletag :integration

  alias DripDrop.{ChannelAdapter, Enrollment, Step}
  alias DripDrop.Channels.SMS.Twilio

  test "posts Twilio Messages API form shape with basic auth and idempotency key" do
    stub_req(fn conn ->
      assert conn.request_path == "/2010-04-01/Accounts/AC123/Messages.json"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Basic QUMxMjM6c2VjcmV0"]
      assert Plug.Conn.get_req_header(conn, "idempotency-key") == ["idem-1"]

      assert form_body(conn) == %{
               "Body" => "Hello SMS",
               "From" => "+15550000000",
               "To" => "+15551234567"
             }

      Req.Test.json(conn, %{"sid" => "SM123"})
    end)

    assert {:ok, %{provider_message_id: "SM123", response: %{status: 200}}} =
             Twilio.deliver(
               step("sms", %{body: "Hello SMS", idempotency_key: "idem-1"}),
               enrollment(),
               adapter()
             )
  end

  test "accepts valid status callback signature and rejects tampering" do
    adapter = adapter()
    url = "https://hooks.example.com/twilio/#{adapter.id}"

    form = %{
      "AccountSid" => "AC123",
      "From" => "+15551234567",
      "MessageSid" => "SM123",
      "MessageStatus" => "delivered",
      "To" => "+15550000000"
    }

    signature = twilio_signature(url, form, "secret")
    request = %{url: url, form: form, headers: %{"x-twilio-signature" => signature}}

    assert :ok = Twilio.verify_signature(adapter, request)

    tampered = put_in(request.form["MessageStatus"], "failed")
    assert {:error, :invalid_signature} = Twilio.verify_signature(adapter, tampered)
  end

  defp adapter(attrs \\ %{}) do
    struct!(
      ChannelAdapter,
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          name: "Twilio",
          tenant_key: "tenant-a",
          channel: "sms",
          provider: "twilio",
          credentials: %{
            "account_sid" => "AC123",
            "auth_token" => "secret",
            "from" => "+15550000000"
          },
          config: %{},
          active: true
        },
        attrs
      )
    )
  end

  defp step(channel, payload) do
    struct!(Step, %{
      channel: channel,
      key: "#{channel}-step",
      config: %{"payload" => payload},
      template_content: %{}
    })
  end

  defp enrollment do
    struct!(Enrollment, %{
      tenant_key: "tenant-a",
      subscriber_type: "user",
      subscriber_id: "ada",
      data: %{"sms" => "+15551234567"}
    })
  end

  defp stub_req(fun) do
    previous = Application.get_env(:dripdrop, :channel_req_options)
    name = :"twilio-provider-#{System.unique_integer([:positive])}"

    Req.Test.stub(name, fun)
    Application.put_env(:dripdrop, :channel_req_options, plug: {Req.Test, name})
    on_exit(fn -> Application.put_env(:dripdrop, :channel_req_options, previous) end)
  end

  defp form_body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    URI.decode_query(body)
  end

  defp twilio_signature(url, form, auth_token) do
    payload =
      form
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.reduce(url, fn {key, value}, acc -> acc <> key <> value end)

    :hmac
    |> :crypto.mac(:sha, auth_token, payload)
    |> Base.encode64()
  end
end
