defmodule DripDrop.ChannelAdaptersTest do
  use DripDrop.DataCase, async: false

  alias DripDrop.{
    Channel,
    ChannelAdapter,
    ChannelAdapters,
    Channels,
    Enrollment,
    Fixtures,
    Step,
    TestRepo
  }

  alias DripDrop.Channels.Email.{Gmail, MailerSend, Ms365}
  alias DripDrop.Channels.PubSub.PhoenixPubSub
  alias DripDrop.Channels.Slack.Webhook, as: SlackWebhook
  alias DripDrop.Channels.SMS.Twilio
  alias DripDrop.Channels.Telegram.BotAPI
  alias DripDrop.Channels.Webhook.Default, as: WebhookDefault
  alias DripDrop.Channels.WhatsApp.CloudAPI
  alias Ecto.Adapters.SQL

  defmodule ResendProvider do
    @moduledoc """
    Test provider used to assert host-defined channel registration.
    """

    @behaviour Channel

    @impl Channel
    def deliver(_step, _enrollment, _adapter) do
      {:ok, %{provider_message_id: "resend_123", response: %{}}}
    end

    @impl Channel
    def validate_credentials(%{"api_key" => api_key}) when is_binary(api_key), do: :ok
    def validate_credentials(%{api_key: api_key}) when is_binary(api_key), do: :ok
    def validate_credentials(_credentials), do: {:error, [api_key: "is required"]}

    @impl Channel
    def webhook_routes(_adapter), do: []

    @impl Channel
    def verify_signature(_adapter, _request), do: :ok
  end

  defmodule TokenCallback do
    @moduledoc """
    OAuth token callback used by Gmail and MS365 provider contract tests.
    """

    @spec fresh(map()) :: {:ok, map()}
    def fresh(_adapter) do
      {:ok, %{access_token: "access-token", expires_at: DateTime.add(DateTime.utc_now(), 60)}}
    end
  end

  describe "adapter storage and validation" do
    test "round-trips encrypted credentials through Ecto and stores ciphertext in Postgres" do
      assert {:ok, adapter} =
               DripDrop.create_channel_adapter(%{
                 tenant_key: "tenant-a",
                 name: "Mailgun",
                 channel: "email",
                 provider: "mailgun",
                 credentials: %{"api_key" => "secret", "domain" => "mg.example.com"}
               })

      raw =
        SQL.query!(
          TestRepo,
          "select encode(credentials, 'escape') from dripdrop.channel_adapters where id::text = $1",
          [adapter.id]
        )

      [[credentials]] = raw.rows
      assert is_binary(credentials)
      refute credentials =~ "secret"

      reloaded = TestRepo.get!(ChannelAdapter, adapter.id)
      assert reloaded.credentials["api_key"] == "secret"
    end

    test "rejects unknown channels and providers" do
      assert {:error, channel_changeset} =
               DripDrop.create_channel_adapter(%{
                 name: "Fax",
                 channel: "fax",
                 provider: "carrier",
                 credentials: %{}
               })

      assert %{channel: [_message]} = errors_on(channel_changeset)

      assert {:error, provider_changeset} =
               DripDrop.create_channel_adapter(%{
                 name: "Carrier",
                 channel: "email",
                 provider: "carrier_pigeon",
                 credentials: %{}
               })

      assert %{provider: [_message]} = errors_on(provider_changeset)
    end

    test "validates provider-required credentials" do
      assert {:error, changeset} =
               DripDrop.create_channel_adapter(%{
                 name: "Mailgun",
                 channel: "email",
                 provider: "mailgun",
                 credentials: %{"api_key" => "secret"}
               })

      assert %{credentials: [_message]} = errors_on(changeset)
    end
  end

  describe "default selection" do
    test "promotes a new default and demotes the previous tenant default atomically" do
      first = Fixtures.channel_adapter_fixture(%{tenant_key: "tenant-a", is_default: true})

      assert {:ok, second} =
               DripDrop.create_channel_adapter(%{
                 tenant_key: "tenant-a",
                 name: "SendGrid",
                 channel: "email",
                 provider: "sendgrid",
                 credentials: %{"api_key" => "secret"},
                 is_default: true
               })

      refute TestRepo.reload!(first).is_default
      assert TestRepo.reload!(second).is_default
    end

    test "falls back from tenant default lookup to a global default" do
      global =
        Fixtures.channel_adapter_fixture(%{
          tenant_key: nil,
          name: "Global SMTP",
          provider: "smtp",
          credentials: %{"relay" => "smtp.example.com"},
          is_default: true
        })

      assert ChannelAdapters.get_default_adapter(:email, "tenant-a").id == global.id
    end
  end

  describe "adapter selection" do
    test "step adapter override wins over defaults" do
      default = Fixtures.channel_adapter_fixture(%{tenant_key: "tenant-a", is_default: true})
      override = Fixtures.channel_adapter_fixture(%{tenant_key: "tenant-a", name: "Override"})

      step = %{channel: "email", tenant_key: "tenant-a", channel_adapter_id: override.id}
      sequence = %{metadata: %{}}
      execution = %{id: Ecto.UUID.generate()}

      assert {:ok, selected} = ChannelAdapters.select(step, sequence, execution)
      assert selected.id == override.id
      refute selected.id == default.id
    end

    test "sequence adapter metadata wins over tenant default" do
      default = Fixtures.channel_adapter_fixture(%{tenant_key: "tenant-a", is_default: true})
      sequence_adapter = Fixtures.channel_adapter_fixture(%{tenant_key: "tenant-a"})

      step = %{channel: "email", tenant_key: "tenant-a", channel_adapter_id: nil, config: %{}}
      sequence = %{metadata: %{"channel_adapters" => %{"email" => sequence_adapter.id}}}
      execution = %{id: Ecto.UUID.generate()}

      assert {:ok, selected} = ChannelAdapters.select(step, sequence, execution)
      assert selected.id == sequence_adapter.id
      refute selected.id == default.id
    end

    test "weighted rotation is sticky for a step execution" do
      first = Fixtures.channel_adapter_fixture(%{tenant_key: "tenant-a", name: "First"})
      second = Fixtures.channel_adapter_fixture(%{tenant_key: "tenant-a", name: "Second"})
      execution = %{id: Ecto.UUID.generate()}

      step = %{
        channel: "email",
        tenant_key: "tenant-a",
        channel_adapter_id: nil,
        config: %{
          "channel_adapter_rotation" => [
            %{"adapter_id" => first.id, "weight" => 70},
            %{"adapter_id" => second.id, "weight" => 30}
          ]
        }
      }

      sequence = %{metadata: %{}}

      assert {:ok, selected} = ChannelAdapters.select(step, sequence, execution)
      assert {:ok, retried} = ChannelAdapters.select(step, sequence, execution)
      assert selected.id == retried.id
      assert selected.id in [first.id, second.id]
    end

    test "returns a permanent no-adapter error when no adapter is available" do
      step = %{channel: "email", tenant_key: "tenant-a", channel_adapter_id: nil, config: %{}}
      sequence = %{metadata: %{}}
      execution = %{id: Ecto.UUID.generate()}

      assert {:error, %{kind: :permanent, reason: :no_adapter}} =
               ChannelAdapters.select(step, sequence, execution)
    end
  end

  describe "provider registry contract" do
    test "accepts a host-registered provider that implements the channel behavior" do
      assert :ok = Channels.register(:email, :resend, ResendProvider)

      assert {:ok, adapter} =
               DripDrop.create_channel_adapter(%{
                 name: "Resend",
                 channel: "email",
                 provider: "resend",
                 credentials: %{"api_key" => "secret"}
               })

      assert adapter.provider == "resend"
    end

    test "shipping providers implement every channel behavior callback" do
      for channel <- Channels.channels(), provider <- Channels.providers(channel) do
        assert {:ok, module} = Channels.provider_module(channel, provider)
        assert {:module, module} = Code.ensure_loaded(module)

        for {function, arity} <- Channel.behaviour_info(:callbacks) do
          assert function_exported?(module, function, arity),
                 "#{inspect(module)} is missing #{function}/#{arity}"
        end
      end
    end

    test "active adapters expose provider-specific webhook routes" do
      mailgun =
        Fixtures.channel_adapter_fixture(%{
          provider: "mailgun",
          credentials: %{"api_key" => "secret", "domain" => "mg.example.com"}
        })

      twilio =
        Fixtures.channel_adapter_fixture(%{
          channel: "sms",
          provider: "twilio",
          credentials: %{
            "account_sid" => "AC123",
            "auth_token" => "secret",
            "from" => "+15551234567"
          }
        })

      routes = DripDrop.Web.webhook_routes()

      assert {:post, "/mailgun/:adapter_id", DripDrop.Channels.Email.Mailgun.WebhookHandler} in routes
      assert {:post, "/twilio/:adapter_id", DripDrop.Channels.SMS.Twilio.WebhookHandler} in routes
      assert mailgun.active
      assert twilio.active
    end
  end

  describe "shipping provider payload contracts" do
    test "MailerSend builds and delivers a Swoosh email payload" do
      adapter =
        adapter(%{
          channel: "email",
          provider: "mailersend",
          credentials: %{"api_key" => "secret", "from" => "team@example.com"},
          config: %{provider_options: [adapter: Swoosh.Adapters.Test]}
        })

      assert {:ok, %{response: %{result: %{}}}} =
               MailerSend.deliver(email_step(), enrollment(), adapter)

      assert_receive {:email, email}
      assert email.subject == "Welcome"
      assert email.text_body == "Hello"
      assert email.to == [{"", "ada@example.com"}]
      assert email.from == {"", "team@example.com"}
    end

    test "webhook provider posts Standard Webhooks shaped payloads" do
      stub_req(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/dripdrop"
        assert Plug.Conn.get_req_header(conn, "webhook-signature") != []

        body = json_body(conn)
        assert body["type"] == "user.created"
        assert body["name"] == "Ada"

        Req.Test.json(conn, %{"ok" => true})
      end)

      adapter =
        adapter(%{
          channel: "webhook",
          provider: "default",
          credentials: %{"url" => "https://hooks.example.com/dripdrop", "secret" => "whsec_test"}
        })

      step =
        step("webhook", %{
          url: "https://hooks.example.com/dripdrop",
          type: "user.created",
          body: %{name: "Ada"}
        })

      assert {:ok, %{response: %{status: 200, body: %{"ok" => true}}}} =
               WebhookDefault.deliver(step, enrollment(), adapter)
    end

    test "Slack, Telegram, WhatsApp, and Twilio round-trip fixture payloads through Req" do
      stub_req(fn conn ->
        body = json_or_form_body(conn)

        response =
          case conn.request_path do
            "/slack" ->
              assert body["text"] == "Build shipped"
              %{"ok" => true}

            "/botbot-token/sendMessage" ->
              assert body["chat_id"] == "chat-1"
              assert body["text"] == "Hello Telegram"
              %{"ok" => true, "result" => %{"message_id" => 123}}

            "/v23.0/phone-1/messages" ->
              assert body["to"] == "+15551234567"
              %{"messages" => [%{"id" => "wamid.123"}]}

            "/2010-04-01/Accounts/AC123/Messages.json" ->
              assert body["To"] == "+15551234567"
              assert body["Body"] == "Hello SMS"
              assert Plug.Conn.get_req_header(conn, "idempotency-key") == ["idem-1"]
              %{"sid" => "SM123"}
          end

        Req.Test.json(conn, response)
      end)

      assert {:ok, %{response: %{status: 200}}} =
               SlackWebhook.deliver(
                 step("slack", %{text: "Build shipped"}),
                 enrollment(),
                 adapter(%{
                   channel: "slack",
                   provider: "webhook",
                   credentials: %{"url" => "https://chat.example.com/slack"}
                 })
               )

      assert {:ok, %{provider_message_id: "123"}} =
               BotAPI.deliver(
                 step("telegram", %{text: "Hello Telegram"}),
                 enrollment(),
                 adapter(%{
                   channel: "telegram",
                   provider: "bot_api",
                   credentials: %{"bot_token" => "bot-token", "chat_id" => "chat-1"}
                 })
               )

      assert {:ok, %{provider_message_id: "wamid.123"}} =
               CloudAPI.deliver(
                 step("whatsapp", %{to: "+15551234567", text: %{body: "Hello"}}),
                 enrollment(),
                 adapter(%{
                   channel: "whatsapp",
                   provider: "cloud_api",
                   credentials: %{"access_token" => "token", "phone_number_id" => "phone-1"}
                 })
               )

      assert {:ok, %{provider_message_id: "SM123"}} =
               Twilio.deliver(
                 step("sms", %{body: "Hello SMS", idempotency_key: "idem-1"}),
                 enrollment(),
                 adapter(%{
                   channel: "sms",
                   provider: "twilio",
                   credentials: %{
                     "account_sid" => "AC123",
                     "auth_token" => "secret",
                     "from" => "+15550000000"
                   }
                 })
               )
    end

    test "Gmail and MS365 use host-provided tokens and provider payload shapes" do
      stub_req(fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer access-token"]

        response =
          case conn.request_path do
            "/gmail/v1/users/me/messages/send" ->
              assert %{"raw" => raw} = json_body(conn)
              assert Base.url_decode64!(raw, padding: false) =~ "Subject: Welcome"
              %{"id" => "gmail-msg-1"}

            "/v1.0/users/ada%40example.com/sendMail" ->
              body = json_body(conn)
              assert get_in(body, ["message", "subject"]) == "Welcome"

              assert get_in(body, ["message", "toRecipients"]) == [
                       %{"emailAddress" => %{"address" => "ada@example.com"}}
                     ]

              %{"id" => "graph-msg-1"}
          end

        Req.Test.json(conn, response)
      end)

      adapter =
        adapter(%{
          channel: "email",
          provider: "gmail",
          credentials: %{
            token_callback: {TokenCallback, :fresh},
            user_email: "ada@example.com"
          }
        })

      assert {:ok, %{provider_message_id: "gmail-msg-1"}} =
               Gmail.deliver(email_step(), enrollment(), adapter)

      adapter = %{adapter | provider: "ms365"}

      assert {:ok, %{provider_message_id: "graph-msg-1"}} =
               Ms365.deliver(email_step(), enrollment(), adapter)
    end

    test "Phoenix PubSub broadcasts the rendered payload" do
      pubsub = :"DripDrop.TestPubSub#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})
      Phoenix.PubSub.subscribe(pubsub, "dripdrop")

      adapter =
        adapter(%{
          channel: "pubsub",
          provider: "phoenix_pubsub",
          credentials: %{pubsub: pubsub, topic: "dripdrop"}
        })

      assert {:ok, %{response: %{topic: "dripdrop", event: "welcome"}}} =
               PhoenixPubSub.deliver(
                 step("pubsub", %{event: "welcome", payload: %{name: "Ada"}}),
                 enrollment(),
                 adapter
               )

      assert_receive {"welcome", %{name: "Ada"}}
    end
  end

  defp adapter(attrs) do
    attrs =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          name: "Fixture adapter",
          tenant_key: "tenant-a",
          credentials: %{},
          config: %{},
          active: true
        },
        attrs
      )

    struct!(ChannelAdapter, attrs)
  end

  defp email_step do
    step("email", %{
      from: "team@example.com",
      to: "ada@example.com",
      subject: "Welcome",
      text: "Hello",
      idempotency_key: "idem-email"
    })
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
      data: %{"email" => "ada@example.com", "sms" => "+15551234567"}
    })
  end

  defp stub_req(fun) do
    previous = Application.get_env(:dripdrop, :channel_req_options)
    name = :"channel-req-#{System.unique_integer([:positive])}"

    Req.Test.stub(name, fun)
    Application.put_env(:dripdrop, :channel_req_options, plug: {Req.Test, name})
    on_exit(fn -> Application.put_env(:dripdrop, :channel_req_options, previous) end)
  end

  defp json_or_form_body(conn) do
    content_type = conn |> Plug.Conn.get_req_header("content-type") |> List.first() |> to_string()

    if String.starts_with?(content_type, "application/x-www-form-urlencoded") do
      conn
      |> raw_body()
      |> URI.decode_query()
    else
      json_body(conn)
    end
  end

  defp json_body(conn), do: conn |> raw_body() |> Jason.decode!()

  defp raw_body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    body
  end
end
