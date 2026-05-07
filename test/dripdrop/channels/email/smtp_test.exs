defmodule DripDrop.Channels.Email.SMTPTest do
  @moduledoc """
  Provider contract tests for `DripDrop.Channels.Email.SMTP`.

  Unlike API-shaped email providers, the SMTP adapter does not produce a
  JSON request body. The two contracts these tests pin are:

    * `SwooshDelivery.config/3` returns a keyword list whose keys are the
      canonical `Swoosh.Adapters.SMTP` options (relay, port, ssl, tls, auth,
      username, password, retries, no_mx_lookups, dkim).
    * `deliver/3` produces a `%Swoosh.Email{}` with the standard fields
      (from, to, subject, text/html bodies, optional reply-to, cc, bcc,
      headers) which Swoosh then renders into a MIME message carrying the
      RFC 5322 / RFC 2045 standard headers (From, To, Subject, Date,
      Message-ID, MIME-Version, Content-Type) when the SMTP adapter
      delivers it.

  The tests swap `Swoosh.Adapters.SMTP` for `Swoosh.Adapters.Test` via the
  adapter's `provider_options` so we can assert on the produced
  `%Swoosh.Email{}` without opening an SMTP connection.
  """

  use ExUnit.Case, async: true

  alias DripDrop.{ChannelAdapter, Enrollment, Step}
  alias DripDrop.Channels.Email.{SMTP, SwooshDelivery}
  alias DripDrop.Fixtures.EmailProviders.SMTP, as: SMTPFixtures

  # `Swoosh.Adapters.Test.deliver/2` sends `{:email, email}` to the calling
  # process - no separate process needs to be started. We use the Test adapter
  # via `provider_options: [adapter: Swoosh.Adapters.Test]` on the channel
  # adapter config so unit tests stay offline.

  describe "deliver/3 with Swoosh.Adapters.Test" do
    test "builds a Swoosh.Email with required headers and bodies" do
      adapter =
        adapter_struct(%{
          credentials: SMTPFixtures.submission_starttls_credentials(),
          config: SMTPFixtures.test_adapter_only_config()
        })

      assert {:ok, %{response: %{result: %{}}}} =
               SMTP.deliver(basic_email_step(), enrollment_struct(), adapter)

      assert_receive {:email, %Swoosh.Email{} = email}

      assert email.from == {"", "team@example.com"}
      assert email.to == [{"", "ada@example.com"}]
      assert email.subject == "Welcome"
      assert email.text_body == "Hello"
      assert email.html_body == "<p>Hello</p>"
      # Idempotency header DripDrop always stamps on outbound email.
      assert {"X-DripDrop-Idempotency-Key", "idem-smtp"} in email.headers
    end

    test "carries reply-to, cc, bcc, and custom headers through to the email" do
      adapter =
        adapter_struct(%{
          credentials: SMTPFixtures.submission_starttls_credentials(),
          config: SMTPFixtures.test_adapter_only_config()
        })

      step =
        step_struct(%{
          payload: SMTPFixtures.rich_payload()
        })

      assert {:ok, _} = SMTP.deliver(step, enrollment_struct(), adapter)

      assert_receive {:email, %Swoosh.Email{} = email}

      assert email.from == {"Team", "team@example.com"}
      assert email.to == [{"Ada Lovelace", "ada@example.com"}]
      assert email.reply_to == {"Support", "support@example.com"}
      assert email.cc == [{"Manager", "manager@example.com"}]
      assert email.bcc == [{"", "audit@example.com"}]
      assert email.subject == "Welcome aboard"
      assert email.text_body =~ "Hello Ada"
      assert email.html_body =~ "<p>Hello Ada"
      assert {"X-Campaign", "welcome-2026"} in email.headers
    end
  end

  describe "SwooshDelivery.config/3 keyword list" do
    @smtp_keys [
      :relay,
      :username,
      :password,
      :port,
      :ssl,
      :tls,
      :auth,
      :retries,
      :no_mx_lookups,
      :dkim
    ]

    test "forwards STARTTLS submission credentials (relay/port/username/password/tls/auth)" do
      adapter =
        adapter_struct(%{
          credentials: SMTPFixtures.submission_starttls_credentials(),
          config: SMTPFixtures.submission_adapter_config()
        })

      config = SwooshDelivery.config(adapter, Swoosh.Adapters.SMTP, @smtp_keys)

      # `provider_options` overrides the adapter so unit tests stay offline.
      assert Keyword.fetch!(config, :adapter) == Swoosh.Adapters.Test
      assert Keyword.fetch!(config, :relay) == "smtp.sendgrid.net"
      assert Keyword.fetch!(config, :port) == 587
      assert Keyword.fetch!(config, :username) == "apikey"
      assert Keyword.fetch!(config, :password) == "SG.test-password"
      assert Keyword.fetch!(config, :tls) == "always"
      assert Keyword.fetch!(config, :auth) == "always"
      assert Keyword.fetch!(config, :retries) == 2
      assert Keyword.fetch!(config, :no_mx_lookups) == true
      # ssl is not configured for STARTTLS - must not appear in the keyword list.
      refute Keyword.has_key?(config, :ssl)
    end

    test "forwards SMTPS (port 465 / ssl: true) credentials and DKIM block" do
      adapter =
        adapter_struct(%{
          credentials: SMTPFixtures.smtps_credentials(),
          config: SMTPFixtures.dkim_adapter_config()
        })

      config = SwooshDelivery.config(adapter, Swoosh.Adapters.SMTP, @smtp_keys)

      assert Keyword.fetch!(config, :relay) == "smtp.gmail.com"
      assert Keyword.fetch!(config, :port) == 465
      assert Keyword.fetch!(config, :ssl) == true
      assert Keyword.fetch!(config, :auth) == "always"

      # DKIM is forwarded as-is from adapter.config, since it's not a credential.
      dkim = Keyword.fetch!(config, :dkim)
      assert Keyword.fetch!(dkim, :s) == "default"
      assert Keyword.fetch!(dkim, :d) == "example.com"
      assert {:pem_plain, _pem} = Keyword.fetch!(dkim, :private_key)

      # No tls/STARTTLS in this profile - implicit TLS via ssl only.
      refute Keyword.has_key?(config, :tls)
    end

    test "omits unset optional keys for an unauthenticated port-25 relay" do
      adapter =
        adapter_struct(%{
          credentials: SMTPFixtures.plain_relay_credentials(),
          config: SMTPFixtures.test_adapter_only_config()
        })

      config = SwooshDelivery.config(adapter, Swoosh.Adapters.SMTP, @smtp_keys)

      assert Keyword.fetch!(config, :relay) == "mta.internal.example.com"
      assert Keyword.fetch!(config, :port) == 25
      assert Keyword.fetch!(config, :auth) == "never"

      # No credentials set - keys must be absent (Swoosh.Adapters.SMTP rejects
      # nil values for these), not present-with-nil.
      refute Keyword.has_key?(config, :username)
      refute Keyword.has_key?(config, :password)
      refute Keyword.has_key?(config, :ssl)
      refute Keyword.has_key?(config, :tls)
      refute Keyword.has_key?(config, :retries)
      refute Keyword.has_key?(config, :dkim)
    end
  end

  # ---------- helpers ----------

  defp adapter_struct(attrs) do
    base = %{
      id: Ecto.UUID.generate(),
      name: "SMTP fixture",
      tenant_key: "tenant-a",
      channel: "email",
      provider: "smtp",
      credentials: %{},
      config: %{},
      active: true
    }

    struct!(ChannelAdapter, Map.merge(base, attrs))
  end

  defp basic_email_step do
    step_struct(%{
      payload: %{
        from: "team@example.com",
        to: "ada@example.com",
        subject: "Welcome",
        text: "Hello",
        html: "<p>Hello</p>",
        idempotency_key: "idem-smtp"
      }
    })
  end

  defp step_struct(%{payload: payload}) do
    struct!(Step, %{
      channel: "email",
      key: "smtp-step",
      config: %{"payload" => payload},
      template_content: %{}
    })
  end

  defp enrollment_struct do
    struct!(Enrollment, %{
      tenant_key: "tenant-a",
      subscriber_type: "user",
      subscriber_id: "ada",
      data: %{"email" => "ada@example.com"}
    })
  end
end
