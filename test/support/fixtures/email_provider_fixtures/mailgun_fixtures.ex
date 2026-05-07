defmodule DripDrop.Fixtures.Email.Mailgun do
  @moduledoc """
  Real-shape fixtures for Mailgun `POST /v3/{domain}/messages` requests and
  responses.

  Captured from the official Mailgun API documentation as of 2026-05-07.

  Sources:
    * https://documentation.mailgun.com/docs/mailgun/api-reference/send/mailgun/messages/post-v3--domain-name--messages.md
    * https://mailgun-docs.redoc.ly/docs/mailgun/api-reference/openapi-final/tag/Messages/
    * https://mailgun-docs.redoc.ly/docs/mailgun/user-manual/sending-messages/
    * https://documentation.mailgun.com/docs/mailgun/user-manual/tracking-messages
    * https://github.com/swoosh/swoosh/blob/main/lib/swoosh/adapters/mailgun.ex

  These fixtures are reference values: tests assert against them so any drift
  in Mailgun's documented contract surfaces as a clear test failure rather
  than a silent breakage in production.
  """

  @doc """
  A 200 success response from `POST /v3/{domain}/messages`.

  Mailgun returns a queued-message confirmation containing the RFC-2392
  message id and a human-readable status.
  """
  def success_response do
    %{
      "id" => "<20260507120000.1.ABCDEF1234567890@mg.example.com>",
      "message" => "Queued. Thank you."
    }
  end

  @doc """
  A 400 response shape for an invalid recipient.
  """
  def error_response_invalid_recipient do
    {400, %{"message" => "'to' parameter is not a valid address. please check documentation"}}
  end

  @doc """
  A 401 response shape for an unauthorized API call.
  """
  def error_response_unauthorized do
    {401, %{"message" => "Forbidden"}}
  end

  @doc """
  A 5xx response shape for a transient Mailgun outage.
  """
  def error_response_server_error do
    {502, %{"message" => "Bad Gateway"}}
  end

  @doc """
  Multipart form fields Mailgun accepts on the messages endpoint, organized
  by purpose so tests can assert documented field names exist verbatim.

  Reference:
    https://mailgun-docs.redoc.ly/docs/mailgun/api-reference/openapi-final/tag/Messages/
  """
  def expected_request_fields(:basic) do
    ["from", "to", "subject", "text", "html"]
  end

  def expected_request_fields(:recipients) do
    ["from", "to", "cc", "bcc", "h:Reply-To"]
  end

  def expected_request_fields(:tracking_and_tags) do
    ["o:tag", "o:tracking", "o:tracking-clicks", "o:tracking-opens", "o:dkim"]
  end

  def expected_request_fields(:headers_and_vars) do
    ["h:X-My-Header", "v:my-var", "t:variables", "recipient-variables"]
  end

  @doc """
  Full multipart form-data field name catalog Mailgun accepts on
  `POST /v3/{domain}/messages`.
  """
  def documented_fields do
    expected_request_fields(:basic) ++
      expected_request_fields(:recipients) ++
      expected_request_fields(:tracking_and_tags) ++
      expected_request_fields(:headers_and_vars) ++
      ["attachment", "inline", "template", "t:version", "t:text"]
  end

  @doc """
  A reference DripDrop step payload that exercises the documented Mailgun
  fields end-to-end. Tests use this to ensure DripDrop -> Swoosh translation
  forwards every documented field type Mailgun supports.
  """
  def reference_payload do
    %{
      from: %{name: "Avengers HQ", email: "noreply@mg.example.com"},
      to: %{name: "Steve Rogers", email: "steve@example.com"},
      cc: ["bruce@example.com"],
      bcc: [%{name: "Nick Fury", email: "fury@example.com"}],
      reply_to: %{name: "Support", email: "support@mg.example.com"},
      subject: "Welcome to the Avengers",
      text: "Hello Steve!",
      html: "<h1>Hello Steve!</h1>",
      headers: %{"X-Campaign-Id" => "welcome-2026-q2"},
      provider_options: %{
        tags: ["welcome", "onboarding"],
        custom_vars: %{"user_id" => "42", "campaign" => "Q2-2026"},
        sending_options: %{"tracking" => "yes", "dkim" => "yes"}
      }
    }
  end
end
