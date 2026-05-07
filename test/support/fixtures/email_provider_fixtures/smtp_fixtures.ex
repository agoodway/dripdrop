defmodule DripDrop.Fixtures.EmailProviders.SMTP do
  @moduledoc """
  SMTP wire-protocol oriented fixtures for the SMTP email provider tests.

  Unlike the API-shaped JSON fixtures (Postmark, SendGrid, Mailgun), SMTP has
  no JSON request body. Instead, the contract this provider is asked to satisfy
  is twofold:

    1. The Swoosh adapter keyword list passed to `Swoosh.Adapters.SMTP`
       (relay, port, ssl, tls, auth, username, password, retries,
       no_mx_lookups, dkim) must conform to the option list documented by
       `Swoosh.Adapters.SMTP`, which is itself a thin wrapper over `gen_smtp`.
    2. The MIME message Swoosh constructs for delivery must include the
       standard headers required for an Internet email message
       (RFC 5322 sec. 3.6).

  ## Sources

    * `Swoosh.Adapters.SMTP` HexDocs:
      https://hexdocs.pm/swoosh/Swoosh.Adapters.SMTP.html
    * `Swoosh.Adapters.SMTP` source:
      https://github.com/swoosh/swoosh/blob/main/lib/swoosh/adapters/smtp.ex
    * `gen_smtp_client.options/0` (the underlying option type):
      https://hexdocs.pm/gen_smtp/gen_smtp_client.html#type-options
    * RFC 5321 - Simple Mail Transfer Protocol:
      https://datatracker.ietf.org/doc/html/rfc5321
    * RFC 5322 - Internet Message Format (header field requirements,
      sec. 3.6 "Field Definitions"):
      https://datatracker.ietf.org/doc/html/rfc5322#section-3.6
    * RFC 2045 - MIME Part One: Format of Internet Message Bodies
      (Content-Type, MIME-Version):
      https://datatracker.ietf.org/doc/html/rfc2045

  Pulled on 2026-05-07.
  """

  @doc """
  Standard MIME header set Swoosh's SMTP rendering layer always carries on a
  generated `%Swoosh.Email{}`.

  Per RFC 5322 sec. 3.6, the originator (`From:`) and `Date:` fields are
  required; `Message-ID:` is "should" but is universally present in modern
  mail. `MIME-Version:` and `Content-Type:` are required by RFC 2045 for any
  message that includes a MIME body (which Swoosh always emits).

  These keys are the canonical RFC names; comparisons in tests should be
  case-insensitive since the SMTP layer may normalize header casing.
  """
  def standard_mime_headers do
    [
      "From",
      "To",
      "Subject",
      "Date",
      "Message-ID",
      "MIME-Version",
      "Content-Type"
    ]
  end

  @doc """
  Submission-port (587) STARTTLS relay credentials.

  This is the conventional configuration for SMTP submission to a public
  relay (SendGrid, Mailgun SMTP, Amazon SES SMTP, Postmark SMTP, etc.):
  port 587 with `tls: :always` and `auth: :always`.
  """
  def submission_starttls_credentials do
    %{
      "relay" => "smtp.sendgrid.net",
      "username" => "apikey",
      "password" => "SG.test-password",
      "port" => 587,
      "tls" => "always",
      "auth" => "always"
    }
  end

  @doc """
  Implicit-TLS (SMTPS) credentials on port 465.

  Some providers (notably Gmail and some legacy submission endpoints) accept
  implicit TLS on port 465. Configured with `ssl: true` and `auth: :always`,
  no STARTTLS upgrade.
  """
  def smtps_credentials do
    %{
      "relay" => "smtp.gmail.com",
      "username" => "team@example.com",
      "password" => "app-specific-password",
      "port" => 465,
      "ssl" => true,
      "auth" => "always"
    }
  end

  @doc """
  Plain (port 25) relay credentials, e.g. an internal MTA that does not
  require authentication. `auth: :never` skips AUTH negotiation.
  """
  def plain_relay_credentials do
    %{
      "relay" => "mta.internal.example.com",
      "port" => 25,
      "auth" => "never"
    }
  end

  @doc """
  Adapter `config` map carrying optional SMTP knobs (retries, no_mx_lookups)
  and the test-adapter override used to keep Swoosh's `Mailer.deliver/2` from
  hitting the network in unit tests.
  """
  def submission_adapter_config do
    %{
      retries: 2,
      no_mx_lookups: true,
      provider_options: [adapter: Swoosh.Adapters.Test]
    }
  end

  @doc """
  Adapter `config` map carrying a sample DKIM signing block accepted by
  `Swoosh.Adapters.SMTP` (forwarded as-is to `gen_smtp`).
  """
  def dkim_adapter_config do
    %{
      dkim: [
        s: "default",
        d: "example.com",
        private_key: {:pem_plain, "---test pem---"}
      ],
      provider_options: [adapter: Swoosh.Adapters.Test]
    }
  end

  @doc """
  Bare adapter `config` that only swaps in the Swoosh test adapter for
  delivery assertions (no extra knobs).
  """
  def test_adapter_only_config do
    %{provider_options: [adapter: Swoosh.Adapters.Test]}
  end

  @doc """
  Email payload with the broadest set of recipients and headers DripDrop
  forwards through to Swoosh - used to assert reply-to, cc, bcc, and custom
  headers all survive the SMTP delivery path.
  """
  def rich_payload do
    %{
      from: %{name: "Team", email: "team@example.com"},
      to: %{name: "Ada Lovelace", email: "ada@example.com"},
      reply_to: %{name: "Support", email: "support@example.com"},
      cc: [%{name: "Manager", email: "manager@example.com"}],
      bcc: ["audit@example.com"],
      subject: "Welcome aboard",
      text: "Hello Ada,\n\nWelcome to DripDrop.",
      html: "<p>Hello Ada,</p><p>Welcome to DripDrop.</p>",
      headers: %{"X-Campaign" => "welcome-2026"},
      idempotency_key: "idem-smtp-1"
    }
  end
end
