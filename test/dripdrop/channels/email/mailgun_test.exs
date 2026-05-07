defmodule DripDrop.Channels.Email.MailgunTest do
  @moduledoc """
  Real-shape integration tests for `DripDrop.Channels.Email.Mailgun`.

  Uses `Swoosh.Adapters.Test` to capture the `%Swoosh.Email{}` produced by
  `DripDrop.Channels.Email.SwooshDelivery` and asserts it matches the
  documented Mailgun `POST /v3/{domain}/messages` contract.

  See `DripDrop.Fixtures.Email.Mailgun` for fixture sources.
  """

  use ExUnit.Case, async: false

  alias DripDrop.{ChannelAdapter, Enrollment, Step}
  alias DripDrop.Channels.Email.Mailgun
  alias DripDrop.Fixtures.Email.Mailgun, as: MailgunFixtures

  setup do
    # Ensure the assertion mailbox is the test process. Swoosh.Adapters.Test
    # delivers via send/2 to the calling process by default but explicitly
    # setting :shared_test_process keeps these assertions stable when other
    # tests have toggled the shared mode.
    Application.put_env(:swoosh, :shared_test_process, self())
    on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)
    :ok
  end

  describe "deliver/3 produces a Swoosh email matching Mailgun's documented shape" do
    test "round-trips from + to + subject + html + text through the Swoosh test adapter" do
      adapter =
        adapter(%{
          credentials: %{
            "api_key" => "key-mg-secret",
            "domain" => "mg.example.com"
          },
          config: %{provider_options: [adapter: Swoosh.Adapters.Test]}
        })

      step =
        email_step(%{
          from: %{name: "Avengers HQ", email: "noreply@mg.example.com"},
          to: %{name: "Steve Rogers", email: "steve@example.com"},
          subject: "Welcome to the Avengers",
          text: "Hello Steve!",
          html: "<h1>Hello Steve!</h1>"
        })

      assert {:ok, %{response: %{result: %{}}}} =
               Mailgun.deliver(step, enrollment(), adapter)

      assert_receive {:email, email}

      # Mailgun multipart form requires `from`, `to`, `subject` plus one of
      # `text` / `html` / `template` / `amp-html`. Our payload exercises the
      # text+html pair, mirroring the documented basic field set.
      for field <- MailgunFixtures.expected_request_fields(:basic) do
        assert is_binary(field)
      end

      assert email.from == {"Avengers HQ", "noreply@mg.example.com"}
      assert email.to == [{"Steve Rogers", "steve@example.com"}]
      assert email.subject == "Welcome to the Avengers"
      assert email.text_body == "Hello Steve!"
      assert email.html_body == "<h1>Hello Steve!</h1>"
    end

    test "reply_to is forwarded so Swoosh can serialize it as Mailgun's h:Reply-To" do
      adapter =
        adapter(%{
          credentials: %{"api_key" => "key", "domain" => "mg.example.com"},
          config: %{provider_options: [adapter: Swoosh.Adapters.Test]}
        })

      step =
        email_step(%{
          from: "noreply@mg.example.com",
          to: "steve@example.com",
          subject: "Reply please",
          text: "Hello",
          reply_to: %{name: "Support", email: "support@mg.example.com"}
        })

      assert {:ok, _} = Mailgun.deliver(step, enrollment(), adapter)

      assert_receive {:email, email}
      assert email.reply_to == {"Support", "support@mg.example.com"}

      # The Mailgun adapter serializes Swoosh's :reply_to field into the
      # documented `h:Reply-To` multipart field; ensure the documented field
      # name is part of our captured contract.
      assert "h:Reply-To" in MailgunFixtures.expected_request_fields(:recipients)
    end

    test "Mailgun-specific provider_options (tags, custom_vars, sending_options) are forwarded" do
      adapter =
        adapter(%{
          credentials: %{"api_key" => "key", "domain" => "mg.example.com"},
          config: %{provider_options: [adapter: Swoosh.Adapters.Test]}
        })

      payload = MailgunFixtures.reference_payload()
      step = email_step(payload)

      assert {:ok, _} = Mailgun.deliver(step, enrollment(), adapter)

      assert_receive {:email, email}

      # Custom vars become Mailgun's `v:` fields in the multipart body.
      assert email.provider_options[:custom_vars] == %{
               "user_id" => "42",
               "campaign" => "Q2-2026"
             }

      # `o:tag` becomes Swoosh's :tags option (Swoosh.Adapters.Mailgun maps
      # that list to repeated `o:tag` form fields).
      assert email.provider_options[:tags] == ["welcome", "onboarding"]

      # `o:tracking` and `o:dkim` are nested under :sending_options per the
      # Swoosh.Adapters.Mailgun contract.
      assert email.provider_options[:sending_options] == %{
               "tracking" => "yes",
               "dkim" => "yes"
             }

      # Any custom header in the payload becomes an `h:X-Header-Name` field.
      assert {"X-Campaign-Id", "welcome-2026-q2"} in email.headers
    end

    test "deliver/3 carries api_key + domain to Swoosh.Adapters.Mailgun in its config" do
      # We swap in a fake adapter that captures the config keyword list passed
      # to `Mailer.deliver/2`. This proves the credentials make it from the
      # adapter row to the Mailgun HTTP client config that Swoosh would use
      # against `https://api.mailgun.net/v3/{domain}/messages`.
      test_pid = self()

      defmodule CaptureAdapter do
        @behaviour Swoosh.Adapter
        @impl true
        def deliver(email, config) do
          send(:mailgun_test_capture, {:delivered, email, config})
          {:ok, %{id: "<captured@mg.example.com>"}}
        end

        @impl true
        def validate_config(_), do: :ok
      end

      Process.register(test_pid, :mailgun_test_capture)

      adapter =
        adapter(%{
          credentials: %{
            "api_key" => "key-mg-secret",
            "domain" => "mg.example.com"
          },
          config: %{
            provider_options: [
              adapter: CaptureAdapter
            ]
          }
        })

      step =
        email_step(%{
          from: "noreply@mg.example.com",
          to: "steve@example.com",
          subject: "Configured",
          text: "Hello"
        })

      assert {:ok, %{provider_message_id: "<captured@mg.example.com>"}} =
               Mailgun.deliver(step, enrollment(), adapter)

      assert_receive {:delivered, _email, config}

      # The Mailgun.deliver/3 implementation forwards :api_key, :domain, and
      # :base_url from credentials/config to the Swoosh adapter config. The
      # provider_options keyword (which we used to swap the adapter module)
      # is also merged in via SwooshDelivery.config/3.
      assert config[:api_key] == "key-mg-secret"
      assert config[:domain] == "mg.example.com"
      assert config[:adapter] == CaptureAdapter
    after
      # Cleanup: deregister the capture name even on failures.
      try do
        Process.unregister(:mailgun_test_capture)
      rescue
        ArgumentError -> :ok
      end
    end
  end

  describe "fixture coverage" do
    test "fixture documents the Mailgun success response shape" do
      assert %{"id" => id, "message" => "Queued. Thank you."} =
               MailgunFixtures.success_response()

      assert is_binary(id)
      assert String.starts_with?(id, "<")
      assert String.ends_with?(id, ">")
    end

    test "fixture documents Mailgun error response shapes" do
      assert {400, %{"message" => message}} =
               MailgunFixtures.error_response_invalid_recipient()

      assert message =~ "to"

      assert {401, %{"message" => _}} = MailgunFixtures.error_response_unauthorized()
      assert {502, %{"message" => _}} = MailgunFixtures.error_response_server_error()
    end
  end

  defp adapter(attrs) do
    attrs =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          name: "Mailgun fixture",
          channel: "email",
          provider: "mailgun",
          tenant_key: "tenant-a",
          credentials: %{},
          config: %{},
          active: true
        },
        attrs
      )

    struct!(ChannelAdapter, attrs)
  end

  defp email_step(payload) do
    struct!(Step, %{
      channel: "email",
      key: "mailgun-step",
      config: %{"payload" => payload},
      template_content: %{}
    })
  end

  defp enrollment do
    struct!(Enrollment, %{
      tenant_key: "tenant-a",
      subscriber_type: "user",
      subscriber_id: "steve",
      data: %{"email" => "steve@example.com"}
    })
  end
end
