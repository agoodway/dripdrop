defmodule DripDrop.Channels.Email.SendGridTest do
  @moduledoc """
  Real-shape integration tests for the SendGrid email adapter.

  These exercise the path `DripDrop.Channels.Email.SendGrid.deliver/3` →
  `DripDrop.Channels.Email.SwooshDelivery` → `Swoosh.Adapters.Test` (a Swoosh-
  provided test adapter that captures the delivered `%Swoosh.Email{}` and
  forwards it to the test process). The shapes flowing through map 1:1 to the
  documented v3 `POST /mail/send` request body
  (https://www.twilio.com/docs/sendgrid/api-reference/mail-send/mail-send,
  pulled 2026-05-07): from / personalizations / subject / content / template_id /
  dynamic_template_data / categories / custom_args / headers.
  """

  use ExUnit.Case, async: true

  alias DripDrop.{ChannelAdapter, Enrollment, Step}
  alias DripDrop.Channels.Email.{SendGrid, SwooshDelivery}

  describe "deliver/3" do
    test "builds a %Swoosh.Email{} with from + to + subject + content" do
      adapter = build_adapter()

      assert {:ok, %{response: %{result: %{}}}} =
               SendGrid.deliver(email_step(), enrollment(), adapter)

      assert_receive {:email, email}
      assert email.from == {"", "team@example.com"}
      assert email.to == [{"", "ada@example.com"}]
      assert email.subject == "Welcome"
      assert email.text_body == "Hello Ada"
      assert email.html_body == "<p>Hello Ada</p>"

      # The DripDrop idempotency key is forwarded as an X- header — this is
      # the documented `headers` object on a SendGrid v3 personalization.
      assert {"X-DripDrop-Idempotency-Key", "idem-001"} in email.headers
    end

    test "forwards categories via provider_options[:categories] (body-level)" do
      adapter = build_adapter()

      step =
        email_step(%{
          provider_options: %{categories: ["digest", "weekly", "tenant-a"]}
        })

      assert {:ok, _} = SendGrid.deliver(step, enrollment(), adapter)

      assert_receive {:email, email}
      assert email.provider_options[:categories] == ["digest", "weekly", "tenant-a"]
    end

    test "forwards template_id + dynamic_template_data via provider_options" do
      adapter = build_adapter()

      step =
        email_step(%{
          subject: nil,
          text: nil,
          html: nil,
          provider_options: %{
            template_id: "d-1234567890abcdef1234567890abcdef",
            dynamic_template_data: %{
              "first_name" => "Ada",
              "order_id" => "ORD-12345"
            }
          }
        })

      assert {:ok, _} = SendGrid.deliver(step, enrollment(), adapter)

      assert_receive {:email, email}

      assert email.provider_options[:template_id] ==
               "d-1234567890abcdef1234567890abcdef"

      assert email.provider_options[:dynamic_template_data] == %{
               "first_name" => "Ada",
               "order_id" => "ORD-12345"
             }
    end

    test "forwards custom_args and arbitrary headers" do
      adapter = build_adapter()

      step =
        email_step(%{
          headers: %{"X-Campaign-Id" => "weekly-2026-19"},
          provider_options: %{
            custom_args: %{
              "campaign_id" => "weekly-2026-19",
              "sequence_key" => "weekly-digest"
            },
            send_at: 1_762_473_600
          }
        })

      assert {:ok, _} = SendGrid.deliver(step, enrollment(), adapter)

      assert_receive {:email, email}

      assert {"X-Campaign-Id", "weekly-2026-19"} in email.headers

      assert email.provider_options[:custom_args] == %{
               "campaign_id" => "weekly-2026-19",
               "sequence_key" => "weekly-digest"
             }

      assert email.provider_options[:send_at] == 1_762_473_600
    end

    test "adapter config carries api_key and optional base_url for EU region" do
      adapter =
        build_adapter(%{
          credentials: %{"api_key" => "SG.test-key", "base_url" => "https://api.eu.sendgrid.com"},
          # Force the regular Sendgrid adapter (not the Test capture adapter)
          # so the delivery raises on the unconfigured HTTP client. We only
          # care that DripDrop hands the right config to Swoosh.
          config: %{}
        })

      config = SwooshDelivery.config(adapter, Swoosh.Adapters.Sendgrid, [:api_key, :base_url])

      assert config[:adapter] == Swoosh.Adapters.Sendgrid
      assert config[:api_key] == "SG.test-key"
      assert config[:base_url] == "https://api.eu.sendgrid.com"
    end
  end

  # ----------------------------------------------------------------------
  # Helpers — local, mirroring the in-test helpers in
  # test/dripdrop/channel_adapters_test.exs so this file stays self-contained.
  # ----------------------------------------------------------------------

  defp build_adapter(overrides \\ %{}) do
    defaults = %{
      id: Ecto.UUID.generate(),
      name: "SendGrid fixture",
      tenant_key: "tenant-a",
      channel: "email",
      provider: "sendgrid",
      credentials: %{"api_key" => "SG.test-key", "from" => "team@example.com"},
      # Route Swoosh to its in-process Test adapter so the call is captured
      # by `assert_receive {:email, _}` rather than hitting the network.
      config: %{provider_options: [adapter: Swoosh.Adapters.Test]},
      active: true
    }

    struct!(ChannelAdapter, Map.merge(defaults, overrides))
  end

  defp email_step(overrides \\ %{}) do
    payload =
      Map.merge(
        %{
          from: "team@example.com",
          to: "ada@example.com",
          subject: "Welcome",
          text: "Hello Ada",
          html: "<p>Hello Ada</p>",
          idempotency_key: "idem-001"
        },
        overrides
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
end
