defmodule DripDrop.Channels.Email.PostmarkTest do
  @moduledoc """
  Real-shape integration tests for the Postmark email provider.

  The Postmark adapter delegates to `Swoosh.Adapters.Postmark` via
  `DripDrop.Channels.Email.SwooshDelivery`. These tests swap the runtime
  Swoosh adapter for `Swoosh.Adapters.Test` (which echoes the built
  `%Swoosh.Email{}` back to the test process) so we can assert the email
  Swoosh would hand to Postmark matches the documented Postmark Email API
  shape.

  Postmark API field reference:

    * `POST /email`            - https://postmarkapp.com/developer/api/email-api
    * `POST /email/withTemplate` - https://postmarkapp.com/developer/api/templates-api

  Postmark `provider_options` recognized by `Swoosh.Adapters.Postmark`
  include `:tag`, `:message_stream`, `:track_opens`, `:track_links`,
  `:metadata`, `:template_id`, `:template_alias`, and `:template_model`.
  """

  use ExUnit.Case, async: true

  alias DripDrop.{ChannelAdapter, Enrollment, Step}
  alias DripDrop.Channels.Email.Postmark
  alias DripDrop.Channels.Email.SwooshDelivery

  describe "deliver/3 transactional sends" do
    test "builds a Swoosh email with from, to, subject, html, and text bodies" do
      adapter = postmark_adapter()

      step =
        email_step(%{
          from: "team@example.com",
          to: "ada@example.com",
          subject: "Postmark test",
          html: "<html><body><strong>Hello</strong> dear Postmark user.</body></html>",
          text: "Hello dear Postmark user."
        })

      assert {:ok, %{response: %{result: %{}}}} = Postmark.deliver(step, enrollment(), adapter)

      assert_receive {:email, email}
      assert email.from == {"", "team@example.com"}
      assert email.to == [{"", "ada@example.com"}]
      assert email.subject == "Postmark test"
      assert email.html_body =~ "<strong>Hello</strong>"
      assert email.text_body == "Hello dear Postmark user."
    end

    test "forwards Tag via provider_options[:tag]" do
      adapter = postmark_adapter()

      step =
        email_step(%{
          subject: "Invitation",
          text: "Welcome",
          provider_options: %{tag: "Invitation"}
        })

      assert {:ok, _} = Postmark.deliver(step, enrollment(), adapter)

      assert_receive {:email, email}
      # Swoosh.Adapters.Postmark reads the Postmark `Tag` field from
      # `provider_options[:tag]`.
      assert email.provider_options[:tag] == "Invitation"
    end

    test "forwards MessageStream for transactional vs broadcast streams" do
      adapter = postmark_adapter()

      transactional_step =
        email_step(%{
          subject: "Outbound",
          text: "Outbound body",
          provider_options: %{message_stream: "outbound"}
        })

      assert {:ok, _} = Postmark.deliver(transactional_step, enrollment(), adapter)
      assert_receive {:email, transactional_email}
      assert transactional_email.provider_options[:message_stream] == "outbound"

      broadcast_step =
        email_step(%{
          subject: "Newsletter",
          text: "Newsletter body",
          provider_options: %{message_stream: "broadcast"}
        })

      assert {:ok, _} = Postmark.deliver(broadcast_step, enrollment(), adapter)
      assert_receive {:email, broadcast_email}
      assert broadcast_email.provider_options[:message_stream] == "broadcast"
    end

    test "forwards TemplateId and TemplateModel for /email/withTemplate sends" do
      adapter = postmark_adapter()

      step =
        email_step(%{
          # Subject/body are intentionally omitted: Postmark's templated
          # endpoint sources them from the template definition.
          provider_options: %{
            template_id: 1234,
            template_model: %{"user_name" => "John Smith"}
          }
        })

      assert {:ok, _} = Postmark.deliver(step, enrollment(), adapter)

      assert_receive {:email, email}
      assert email.provider_options[:template_id] == 1234
      assert email.provider_options[:template_model] == %{"user_name" => "John Smith"}
    end
  end

  describe "adapter configuration" do
    test "passes the api_key (Postmark server token) through to Swoosh.Adapters.Postmark" do
      adapter =
        struct!(ChannelAdapter,
          id: Ecto.UUID.generate(),
          name: "Postmark",
          tenant_key: "tenant-a",
          channel: "email",
          provider: "postmark",
          credentials: %{"api_key" => "pm-server-token-abc123"},
          # Use Swoosh.Adapters.Postmark itself here so we are inspecting the
          # actual config the production adapter would build, then we override
          # to Test below for the live deliver in other tests.
          config: %{},
          active: true
        )

      config = SwooshDelivery.config(adapter, Swoosh.Adapters.Postmark, [:api_key, :base_url])

      assert Keyword.get(config, :adapter) == Swoosh.Adapters.Postmark
      assert Keyword.get(config, :api_key) == "pm-server-token-abc123"
      # Postmark requests are authenticated by `X-Postmark-Server-Token`,
      # which Swoosh derives from this `:api_key`.
    end
  end

  defp postmark_adapter do
    struct!(ChannelAdapter,
      id: Ecto.UUID.generate(),
      name: "Postmark",
      tenant_key: "tenant-a",
      channel: "email",
      provider: "postmark",
      credentials: %{"api_key" => "pm-server-token-test", "from" => "team@example.com"},
      config: %{provider_options: [adapter: Swoosh.Adapters.Test]},
      active: true
    )
  end

  defp email_step(payload_overrides) do
    payload =
      Map.merge(
        %{
          from: "team@example.com",
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
