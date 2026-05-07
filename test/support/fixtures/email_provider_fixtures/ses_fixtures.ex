defmodule DripDrop.Fixtures.EmailProviders.SES do
  @moduledoc """
  Real-shape Amazon SES API request and response fixtures.

  These fixtures mirror the wire-level request and response shapes documented
  for the Amazon SES email-sending APIs. They are intentionally verbatim
  (form-encoded keys for the classic `Action=SendEmail` / `Action=SendRawEmail`
  query API; XML for responses) so tests assert the exact contract the
  Amazon SES endpoint accepts and emits.

  ## Endpoint and authentication

  Amazon SES classic email-sending requests are POSTed as
  `application/x-www-form-urlencoded` to the regional endpoint, e.g.
  `https://email.us-east-1.amazonaws.com/`.

  Requests are signed with **AWS Signature Version 4**:

    * `Authorization: AWS4-HMAC-SHA256 Credential=AKIA.../<date>/<region>/ses/aws4_request, SignedHeaders=..., Signature=...`
    * `X-Amz-Date: 20260507T120000Z`
    * Optional `X-Amz-Security-Token: <token>` when sending with STS credentials.

  Successful responses are XML with the `<SendEmailResponse>` root element.
  Errors are XML with the `<ErrorResponse>` root element.

  ## Sources

    * `Action=SendEmail` request parameters and response:
      https://docs.aws.amazon.com/ses/latest/APIReference/API_SendEmail.html
    * `Action=SendRawEmail` request parameters and response:
      https://docs.aws.amazon.com/ses/latest/APIReference/API_SendRawEmail.html
    * Common errors / error response envelope:
      https://docs.aws.amazon.com/ses/latest/APIReference/CommonErrors.html
    * SES SNS notification examples (bounce/complaint/delivery):
      https://docs.aws.amazon.com/ses/latest/dg/notification-examples.html
    * SNS HTTPS notification JSON envelope:
      https://docs.aws.amazon.com/sns/latest/dg/sns-message-and-json-formats.html
    * SNS message signature verification:
      https://docs.aws.amazon.com/sns/latest/dg/sns-verify-signature-of-message.html
    * AWS SigV4 signing process:
      https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv4_signing.html

  Pulled on 2026-05-07.

  Note: Swoosh's `Swoosh.Adapters.AmazonSES` always uses `Action=SendRawEmail`
  (it builds and base64-encodes a MIME message client-side and ships it as
  `RawMessage.Data`). The `SendEmail` form fixtures here document the
  alternative, simpler classic API surface that an SES integration may target
  directly (and that the SES error envelope is shared between the two).
  """

  @doc """
  Minimal `Action=SendEmail` form-encoded request body, formatted as a
  decoded map for easy assertion. Equivalent to the example in the official
  SES API Reference:

      AWSAccessKeyId=AKIAIOSFODNN7EXAMPLE
      &Action=SendEmail
      &Destination.ToAddresses.member.1=allan%40example.com
      &Message.Body.Text.Data=body
      &Message.Subject.Data=Example
      &Source=user%40example.com
      &Timestamp=2011-08-18T22%3A25%3A27.000Z
  """
  def send_email_request_form do
    %{
      "Action" => "SendEmail",
      "Version" => "2010-12-01",
      "Source" => "sender@example.com",
      "Destination.ToAddresses.member.1" => "ada@example.com",
      "Message.Subject.Data" => "Welcome",
      "Message.Subject.Charset" => "UTF-8",
      "Message.Body.Text.Data" => "Hello dear SES user.",
      "Message.Body.Text.Charset" => "UTF-8",
      "Message.Body.Html.Data" =>
        "<html><body><strong>Hello</strong> dear SES user.</body></html>",
      "Message.Body.Html.Charset" => "UTF-8"
    }
  end

  @doc """
  `Action=SendEmail` request body extended with `ConfigurationSetName` and a
  `Tags.member.N` pair. Configuration sets and message tags are the SES
  primitives that drive event publishing (CloudWatch / Kinesis / SNS).

      Action=SendEmail
      &ConfigurationSetName=newsletter-events
      &Tags.member.1.Name=campaign
      &Tags.member.1.Value=launch
      &Tags.member.2.Name=tier
      &Tags.member.2.Value=pro
  """
  def tagged_send_email_request_form do
    Map.merge(send_email_request_form(), %{
      "ConfigurationSetName" => "newsletter-events",
      "Tags.member.1.Name" => "campaign",
      "Tags.member.1.Value" => "launch",
      "Tags.member.2.Name" => "tier",
      "Tags.member.2.Value" => "pro"
    })
  end

  @doc """
  `Action=SendRawEmail` request body. SES expects the entire MIME message,
  base64-encoded, as `RawMessage.Data`. This is the form Swoosh's
  `Swoosh.Adapters.AmazonSES` builds at runtime.

  Returns `{form_map, raw_mime}` so tests can both inspect the form keys and
  decode `RawMessage.Data` to verify the embedded MIME body.
  """
  def send_raw_email_request_form do
    raw_mime =
      Enum.join(
        [
          "From: sender@example.com",
          "To: ada@example.com",
          "Subject: Welcome",
          "MIME-Version: 1.0",
          "Content-Type: multipart/alternative; boundary=\"boundary42\"",
          "",
          "--boundary42",
          "Content-Type: text/plain; charset=\"UTF-8\"",
          "",
          "Hello dear SES user.",
          "",
          "--boundary42",
          "Content-Type: text/html; charset=\"UTF-8\"",
          "",
          "<html><body><strong>Hello</strong> dear SES user.</body></html>",
          "",
          "--boundary42--"
        ],
        "\r\n"
      )

    form = %{
      "Action" => "SendRawEmail",
      "Version" => "2010-12-01",
      "RawMessage.Data" => Base.encode64(raw_mime),
      "Source" => "sender@example.com",
      "Destinations.member.1" => "ada@example.com",
      # ConfigurationSetName / Tags.member.N are equally valid on SendRawEmail
      # and are documented as parameters that override their X-SES-* header
      # equivalents in the raw MIME.
      "ConfigurationSetName" => "newsletter-events",
      "Tags.member.1.Name" => "campaign",
      "Tags.member.1.Value" => "launch"
    }

    {form, raw_mime}
  end

  @doc """
  Successful `Action=SendEmail` XML response. SES echoes a `MessageId` and a
  `RequestId` inside the `<ResponseMetadata>`. Swoosh's adapter parses this
  XML and exposes the `MessageId` value.
  """
  def send_email_success_xml do
    """
    <SendEmailResponse xmlns="http://ses.amazonaws.com/doc/2010-12-01/">
      <SendEmailResult>
        <MessageId>0102018f4b0d9abc-11111111-2222-3333-4444-555555555555-000000</MessageId>
      </SendEmailResult>
      <ResponseMetadata>
        <RequestId>d5964849-c866-11e0-9beb-01a62d68c57f</RequestId>
      </ResponseMetadata>
    </SendEmailResponse>
    """
  end

  @doc """
  Successful `Action=SendRawEmail` XML response. Identical envelope to
  `SendEmail`, but the result element is `<SendRawEmailResult>`.
  """
  def send_raw_email_success_xml do
    """
    <SendRawEmailResponse xmlns="http://ses.amazonaws.com/doc/2010-12-01/">
      <SendRawEmailResult>
        <MessageId>0102018f4b0d9abc-22222222-3333-4444-5555-666666666666-000000</MessageId>
      </SendRawEmailResult>
      <ResponseMetadata>
        <RequestId>e0c2ad04-c866-11e0-9beb-01a62d68c57f</RequestId>
      </ResponseMetadata>
    </SendRawEmailResponse>
    """
  end

  @doc """
  Error XML response. SES returns the standard AWS query-API
  `<ErrorResponse>` envelope, e.g. `MessageRejected`, `Throttling`,
  `ConfigurationSetDoesNotExist`. The HTTP status is `400` for client
  errors and `500`+ for server errors.
  """
  def message_rejected_error_xml do
    """
    <ErrorResponse>
      <Error>
        <Type>Sender</Type>
        <Code>MessageRejected</Code>
        <Message>Email address is not verified. The following identities failed the check in region US-EAST-1: sender@example.com</Message>
      </Error>
      <RequestId>2dcd17ee-c866-11e0-9beb-01a62d68c57f</RequestId>
    </ErrorResponse>
    """
  end

  @doc """
  Throttling error returned when an account exceeds its sending quota or
  per-second send rate. Useful for asserting that the adapter classifies the
  error as transient/retryable.
  """
  def throttling_error_xml do
    """
    <ErrorResponse>
      <Error>
        <Type>Sender</Type>
        <Code>Throttling</Code>
        <Message>Maximum sending rate exceeded.</Message>
      </Error>
      <RequestId>3eb22d1a-c866-11e0-9beb-01a62d68c57f</RequestId>
    </ErrorResponse>
    """
  end

  @doc """
  Representative SNS `SubscriptionConfirmation` envelope as posted by SNS to
  the subscribed HTTPS endpoint. The `SubscribeURL` must be GET-fetched once
  for SNS to consider the subscription confirmed.

  The `Signature`, `SigningCertURL`, and `MessageId` here are placeholders;
  real signature verification requires fetching the certificate at
  `SigningCertURL`, building the documented canonical string, and verifying
  with RSA-SHA256 (`SignatureVersion=2`). DripDrop tests this flow at the
  module-canonicalization level rather than against this fixture.
  """
  def sns_subscription_confirmation do
    %{
      "Type" => "SubscriptionConfirmation",
      "MessageId" => "165545c9-2a5c-472c-8df2-7ff2be2b3b1b",
      "Token" => "2336412f37fb687f5d51e6e2425c464de2c56b29d3d6f...",
      "TopicArn" => "arn:aws:sns:us-east-1:123456789012:ses-events",
      "Message" =>
        "You have chosen to subscribe to the topic arn:aws:sns:us-east-1:123456789012:ses-events.\nTo confirm the subscription, visit the SubscribeURL included in this message.",
      "SubscribeURL" =>
        "https://sns.us-east-1.amazonaws.com/?Action=ConfirmSubscription&TopicArn=arn:aws:sns:us-east-1:123456789012:ses-events&Token=2336412f37fb687f5d51e6e2425c464de2c56b29d3d6f...",
      "Timestamp" => "2026-05-07T14:00:00.000Z",
      "SignatureVersion" => "2",
      "Signature" => "BASE64_RSA_SHA256_SIGNATURE",
      "SigningCertURL" =>
        "https://sns.us-east-1.amazonaws.com/SimpleNotificationService-0123456789abcdef.pem"
    }
  end

  @doc """
  Representative SNS `Notification` envelope wrapping an SES bounce event.
  The `Message` field is a JSON string (per SNS conventions) whose body is
  the SES `notificationType=Bounce` payload documented in the SES Developer
  Guide.

  Returns the parsed envelope; the inner `Message` is a JSON-encoded string
  so it round-trips through SNS' canonical signing process.
  """
  def sns_bounce_notification do
    inner_bounce =
      Jason.encode!(%{
        "notificationType" => "Bounce",
        "bounce" => %{
          "bounceType" => "Permanent",
          "bounceSubType" => "General",
          "bouncedRecipients" => [
            %{
              "emailAddress" => "bounced@example.com",
              "action" => "failed",
              "status" => "5.1.1",
              "diagnosticCode" => "smtp; 550 5.1.1 user unknown"
            }
          ],
          "timestamp" => "2026-05-07T14:01:02.000Z",
          "feedbackId" => "0102018f4b0d9abc-77777777-8888-9999-aaaa-bbbbbbbbbbbb-000000",
          "remoteMtaIp" => "127.0.2.0",
          "reportingMTA" => "dns; a8-70.smtp-out.amazonses.com"
        },
        "mail" => %{
          "timestamp" => "2026-05-07T14:00:59.000Z",
          "source" => "sender@example.com",
          "sourceArn" => "arn:aws:ses:us-east-1:123456789012:identity/example.com",
          "sendingAccountId" => "123456789012",
          "messageId" => "0102018f4b0d9abc-11111111-2222-3333-4444-555555555555-000000",
          "destination" => ["bounced@example.com"]
        }
      })

    %{
      "Type" => "Notification",
      "MessageId" => "22b80b92-fdea-4c2c-8f9d-bdfb0c7bf324",
      "TopicArn" => "arn:aws:sns:us-east-1:123456789012:ses-events",
      "Subject" => "Amazon SES Email Event Notification",
      "Message" => inner_bounce,
      "Timestamp" => "2026-05-07T14:01:03.000Z",
      "SignatureVersion" => "2",
      "Signature" => "BASE64_RSA_SHA256_SIGNATURE",
      "SigningCertURL" =>
        "https://sns.us-east-1.amazonaws.com/SimpleNotificationService-0123456789abcdef.pem",
      "UnsubscribeURL" =>
        "https://sns.us-east-1.amazonaws.com/?Action=Unsubscribe&SubscriptionArn=arn:aws:sns:us-east-1:123456789012:ses-events:..."
    }
  end
end
