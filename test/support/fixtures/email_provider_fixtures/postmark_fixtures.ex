defmodule DripDrop.Fixtures.EmailProviders.Postmark do
  @moduledoc """
  Real-shape Postmark Email API request and response fixtures.

  These fixtures mirror the JSON payloads documented in the Postmark Developer
  documentation. They are intentionally verbatim (PascalCase keys, the same
  field names and shapes the live API accepts/returns) so tests assert the
  exact contract a Postmark integration must satisfy.

  ## Authentication

  All Postmark Email API requests authenticate with the
  `X-Postmark-Server-Token` header (the Postmark "server token", which
  DripDrop stores under the `:api_key` credential).

  ## Sources

    * `POST /email` - Single send:
      https://postmarkapp.com/developer/user-guide/send-email-with-api/send-a-single-email
    * `POST /email` - Email API reference:
      https://postmarkapp.com/developer/api/email-api
    * `POST /email/withTemplate` - Templates API:
      https://postmarkapp.com/developer/api/templates-api
    * `POST /email/batch` - Batch send:
      https://postmarkapp.com/developer/api/email-api
    * API error codes:
      https://postmarkapp.com/developer/api/overview#error-codes

  Pulled on 2026-05-07.
  """

  @doc """
  Minimal `POST /email` transactional request body, taken from the Postmark
  developer "send a single email" guide.
  """
  def basic_send_request do
    %{
      "From" => "sender@example.com",
      "To" => "receiver@example.com",
      "Subject" => "Postmark test",
      "TextBody" => "Hello dear Postmark user.",
      "HtmlBody" => "<html><body><strong>Hello</strong> dear Postmark user.</body></html>",
      "MessageStream" => "outbound"
    }
  end

  @doc """
  Full-shape `POST /email` request body, including `Tag`, custom `Headers`,
  `Attachments`, `Metadata`, and tracking flags. Mirrors the example in the
  Email API reference.
  """
  def tagged_send_request do
    %{
      "From" => "sender@example.com",
      "To" => "receiver@example.com",
      "Cc" => "copied@example.com",
      "Bcc" => "blind-copied@example.com",
      "Subject" => "Test",
      "Tag" => "Invitation",
      "HtmlBody" => "<b>Hello</b> <img src=\"cid:image.jpg\"/>",
      "TextBody" => "Hello",
      "ReplyTo" => "reply@example.com",
      "Headers" => [
        %{"Name" => "CUSTOM-HEADER", "Value" => "value"}
      ],
      "TrackOpens" => true,
      "TrackLinks" => "None",
      "Attachments" => [
        %{
          "Name" => "readme.txt",
          "Content" => "dGVzdCBjb250ZW50",
          "ContentType" => "text/plain"
        }
      ],
      "Metadata" => %{
        "color" => "blue",
        "client-id" => "12345"
      },
      "MessageStream" => "outbound"
    }
  end

  @doc """
  `POST /email` request body using the broadcast (non-transactional) message
  stream. Postmark requires `MessageStream` to match a stream configured on
  the server; "broadcast" is the default broadcast stream name.
  """
  def broadcast_send_request do
    %{
      "From" => "newsletter@example.com",
      "To" => "subscriber@example.com",
      "Subject" => "Monthly newsletter",
      "HtmlBody" => "<h1>Hello</h1>",
      "TextBody" => "Hello",
      "MessageStream" => "broadcast"
    }
  end

  @doc """
  `POST /email/withTemplate` request body using a numeric `TemplateId` plus
  `TemplateModel`, copied from the templates API guide.
  """
  def template_id_send_request do
    %{
      "From" => "sender@example.com",
      "To" => "receiver@example.com",
      "TemplateId" => 1234,
      "TemplateModel" => %{
        "user_name" => "John Smith"
      }
    }
  end

  @doc """
  `POST /email/withTemplate` request body using a string `TemplateAlias`
  instead of `TemplateId`. Postmark accepts either, but exactly one must be
  provided per send.
  """
  def template_alias_send_request do
    %{
      "From" => "sender@example.com",
      "To" => "receiver@example.com",
      "TemplateAlias" => "welcome",
      "TemplateModel" => %{
        "user_name" => "John Smith",
        "company" => %{"name" => "ACME"}
      },
      "MessageStream" => "outbound"
    }
  end

  @doc """
  Successful `POST /email` (and `POST /email/withTemplate`) response.

  `ErrorCode` is `0` and `Message` is `"OK"` on success.
  """
  def success_response do
    %{
      "To" => "receiver@example.com",
      "SubmittedAt" => "2023-10-27T10:00:00.1234567Z",
      "MessageID" => "123e4567-e89b-12d3-a456-426614174000",
      "ErrorCode" => 0,
      "Message" => "OK"
    }
  end

  @doc """
  HTTP 401 response for a missing or invalid `X-Postmark-Server-Token`.

  Postmark documents `ErrorCode` 10 as the unauthorized server-token error.
  """
  def unauthorized_response do
    %{
      "ErrorCode" => 10,
      "Message" =>
        "Please verify that you are using a valid token. You can find your tokens on the credentials page."
    }
  end

  @doc """
  HTTP 422 response with `ErrorCode` 300 - "Invalid 'From' address".

  Postmark returns 422 Unprocessable Entity for sender-signature and
  validation failures, with a numeric `ErrorCode` in the body.
  """
  def invalid_sender_response do
    %{
      "ErrorCode" => 300,
      "Message" => "Invalid 'From' address: 'not-a-real-address'."
    }
  end

  @doc """
  HTTP 422 response with `ErrorCode` 406 - "You haven't sent any emails yet"
  account-level inactive sender error. Useful for asserting the adapter
  classifies non-2xx Postmark errors as permanent failures.
  """
  def inactive_recipient_response do
    %{
      "ErrorCode" => 406,
      "Message" => "You tried to send to recipient(s) that have been marked as inactive."
    }
  end
end
