defmodule DripDrop.Channels.Email.SESTest do
  @moduledoc """
  Real-shape integration tests for the Amazon SES email provider.

  The SES adapter delegates to `Swoosh.Adapters.AmazonSES` via
  `DripDrop.Channels.Email.SwooshDelivery`. Swoosh's SES adapter always
  builds an `Action=SendRawEmail` request (it serializes the email to a MIME
  message and base64-encodes it as `RawMessage.Data`), and forwards
  `provider_options[:configuration_set_name]` and `provider_options[:tags]`
  to the SES `ConfigurationSetName` and `Tags.member.N.{Name,Value}` form
  parameters.

  These tests swap the runtime Swoosh adapter for `Swoosh.Adapters.Test`
  (which echoes the built `%Swoosh.Email{}` back to the test process) so we
  can assert the email Swoosh hands to the SES wire-format path matches the
  documented SES API shape without making live HTTPS requests.

  Amazon SES API field reference:

    * `Action=SendEmail`     - https://docs.aws.amazon.com/ses/latest/APIReference/API_SendEmail.html
    * `Action=SendRawEmail`  - https://docs.aws.amazon.com/ses/latest/APIReference/API_SendRawEmail.html
  """

  use ExUnit.Case, async: true

  alias DripDrop.{ChannelAdapter, Enrollment, Step}
  alias DripDrop.Channels.Email.SES
  alias DripDrop.Channels.Email.SwooshDelivery
  alias DripDrop.Fixtures.EmailProviders.SES, as: SESFixtures

  describe "deliver/3 transactional sends" do
    test "builds a Swoosh email with from, to, subject, html_body, and text_body" do
      adapter = ses_adapter()

      step =
        email_step(%{
          from: "sender@example.com",
          to: "ada@example.com",
          subject: "Welcome",
          html: "<html><body><strong>Hello</strong> dear SES user.</body></html>",
          text: "Hello dear SES user."
        })

      assert {:ok, %{response: %{result: %{}}}} = SES.deliver(step, enrollment(), adapter)

      assert_receive {:email, email}
      assert email.from == {"", "sender@example.com"}
      assert email.to == [{"", "ada@example.com"}]
      assert email.subject == "Welcome"
      assert email.html_body =~ "<strong>Hello</strong>"
      assert email.text_body == "Hello dear SES user."

      # Cross-check the wire-shape fixture: the same field values would
      # appear in the form-encoded SendEmail request body that SES expects.
      send_email_form = SESFixtures.send_email_request_form()
      assert send_email_form["Source"] == "sender@example.com"
      assert send_email_form["Destination.ToAddresses.member.1"] == "ada@example.com"
      assert send_email_form["Message.Subject.Data"] == "Welcome"
      assert send_email_form["Action"] == "SendEmail"
    end

    test "forwards ConfigurationSetName via provider_options[:configuration_set_name]" do
      adapter = ses_adapter()

      step =
        email_step(%{
          subject: "Welcome",
          text: "Hello",
          provider_options: %{configuration_set_name: "newsletter-events"}
        })

      assert {:ok, _} = SES.deliver(step, enrollment(), adapter)

      assert_receive {:email, email}
      # `Swoosh.Adapters.AmazonSES` reads `provider_options[:configuration_set_name]`
      # and writes it as the `ConfigurationSetName` form parameter on the
      # SendRawEmail request.
      assert email.provider_options[:configuration_set_name] == "newsletter-events"

      tagged_form = SESFixtures.tagged_send_email_request_form()
      assert tagged_form["ConfigurationSetName"] == "newsletter-events"
    end

    test "forwards Tags.member.N via provider_options[:tags]" do
      adapter = ses_adapter()

      tags = [
        %{name: "campaign", value: "launch"},
        %{name: "tier", value: "pro"}
      ]

      step =
        email_step(%{
          subject: "Welcome",
          text: "Hello",
          provider_options: %{tags: tags}
        })

      assert {:ok, _} = SES.deliver(step, enrollment(), adapter)

      assert_receive {:email, email}
      assert email.provider_options[:tags] == tags

      tagged_form = SESFixtures.tagged_send_email_request_form()
      assert tagged_form["Tags.member.1.Name"] == "campaign"
      assert tagged_form["Tags.member.1.Value"] == "launch"
      assert tagged_form["Tags.member.2.Name"] == "tier"
      assert tagged_form["Tags.member.2.Value"] == "pro"
    end
  end

  describe "adapter configuration" do
    test "passes region, access_key, and secret through to Swoosh.Adapters.AmazonSES" do
      adapter =
        struct!(ChannelAdapter,
          id: Ecto.UUID.generate(),
          name: "Amazon SES",
          tenant_key: "tenant-a",
          channel: "email",
          provider: "ses",
          credentials: %{
            "region" => "us-east-1",
            "access_key" => "AKIAIOSFODNN7EXAMPLE",
            "secret" => "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            "sns_topic_arn" => "arn:aws:sns:us-east-1:123456789012:ses-events"
          },
          config: %{},
          active: true
        )

      config =
        SwooshDelivery.config(adapter, Swoosh.Adapters.AmazonSES, [
          :region,
          :access_key,
          :secret,
          :host
        ])

      assert Keyword.get(config, :adapter) == Swoosh.Adapters.AmazonSES
      assert Keyword.get(config, :region) == "us-east-1"
      assert Keyword.get(config, :access_key) == "AKIAIOSFODNN7EXAMPLE"
      assert Keyword.get(config, :secret) == "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
      # SES requests are signed with AWS SigV4 (Authorization: AWS4-HMAC-SHA256
      # ... / X-Amz-Date), which Swoosh derives from these three credentials.
    end
  end

  describe "verify_signature/2" do
    test "rejects an SNS notification whose TopicArn does not match the configured topic" do
      adapter =
        struct!(ChannelAdapter,
          id: Ecto.UUID.generate(),
          name: "Amazon SES",
          tenant_key: "tenant-a",
          channel: "email",
          provider: "ses",
          credentials: %{
            "region" => "us-east-1",
            "access_key" => "key",
            "secret" => "secret",
            "sns_topic_arn" => "arn:aws:sns:us-east-1:123456789012:ses-events"
          },
          config: %{},
          active: true
        )

      # Use the SubscriptionConfirmation fixture but rewrite the TopicArn to
      # something that does NOT match the adapter's configured topic. SES
      # webhook verification must reject this before any cert fetch happens.
      tampered =
        SESFixtures.sns_subscription_confirmation()
        |> Map.put("TopicArn", "arn:aws:sns:us-east-1:999999999999:other-topic")

      request = %{raw_body: Jason.encode!(tampered)}

      assert {:error, :topic_mismatch} = SES.verify_signature(adapter, request)
    end
  end

  defp ses_adapter do
    struct!(ChannelAdapter,
      id: Ecto.UUID.generate(),
      name: "Amazon SES",
      tenant_key: "tenant-a",
      channel: "email",
      provider: "ses",
      credentials: %{
        "region" => "us-east-1",
        "access_key" => "AKIAIOSFODNN7EXAMPLE",
        "secret" => "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        "sns_topic_arn" => "arn:aws:sns:us-east-1:123456789012:ses-events",
        "from" => "sender@example.com"
      },
      config: %{provider_options: [adapter: Swoosh.Adapters.Test]},
      active: true
    )
  end

  defp email_step(payload_overrides) do
    payload =
      Map.merge(
        %{
          from: "sender@example.com",
          to: "ada@example.com",
          subject: "Welcome",
          text: "Hello"
        },
        payload_overrides
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
