defmodule DripDrop.Fixtures.Webhooks do
  @moduledoc """
  Provider webhook examples copied from current provider documentation.

  These fixtures intentionally keep the raw body and headers together where the
  provider signs raw bytes. Signature values are representative unless the
  fixture notes a concrete test secret.
  """

  @doc """
  Mailgun delivered event with the documented nested signature object.

  Sources:

    * https://documentation.mailgun.com/docs/mailgun/user-manual/webhooks/securing-webhooks
    * https://documentation.mailgun.com/docs/mailgun/user-manual/webhooks/webhook-payloads
  """
  def mailgun_delivered do
    %{
      "signature" => %{
        "token" => "e0b5477167110d68991efc6b9f89f0a11066af27834600e123",
        "timestamp" => "1770920772",
        "signature" => "12d99f5a15355c180971bed7494d578b093c958f57766f3fe750761baed12345"
      },
      "event-data" => %{
        "event" => "delivered",
        "id" => "MXcc2gEpS-eN8HfkOnmK2w",
        "timestamp" => 1_770_146_431.6585283,
        "recipient" => "recipient@sample.mailgun.com",
        "message" => %{
          "headers" => %{
            "message-id" => "20260203192030.53383e583ab41f62@sample.mailgun.com",
            "from" => "Sample Sender <sender@sample.mailgun.com>",
            "to" => "recipient@mailgun.com",
            "subject" => "Sample webhook payload"
          },
          "size" => 341,
          "attachments" => []
        },
        "delivery-status" => %{
          "code" => 250,
          "message" => "OK",
          "attempt-no" => 1
        },
        "domain" => %{"name" => "sample.mailgun.com"},
        "account" => %{"id" => "1234567890303a4bd1f33898"}
      }
    }
  end

  @doc """
  SendGrid delivered event with signed Event Webhook headers.

  Sources:

    * https://www.twilio.com/docs/sendgrid/for-developers/tracking-events/getting-started-event-webhook-security-features
    * https://www.twilio.com/docs/sendgrid/for-developers/tracking-events/event
  """
  def sendgrid_delivered do
    raw_body =
      ~s([{"email":"alex@example.com","timestamp":1513299569,"smtp-id":"<14c5d75ce93.dfd.64b469@ismtpd-555>","event":"delivered","category":"cat facts","sg_event_id":"rWVYmVk90MjZJ9iohOBa3w==","sg_message_id":"14c5d75ce93.dfd.64b469.filter0001.16648.5515E0B88.0","response":"250 OK"}])

    %{
      headers: %{
        "x-twilio-email-event-webhook-signature" => "BASE64_ASN1_ECDSA_SIGNATURE",
        "x-twilio-email-event-webhook-timestamp" => "1513299569",
        "content-type" => "application/json"
      },
      raw_body: raw_body,
      parsed_body: Jason.decode!(raw_body)
    }
  end

  @doc """
  Postmark delivery webhook.

  Sources:

    * https://postmarkapp.com/developer/webhooks/delivery-webhook
    * https://postmarkapp.com/developer/webhooks/webhooks-overview
  """
  def postmark_delivery do
    %{
      provider: :postmark,
      verification: %{
        scheme: :basic_auth_or_custom_header,
        headers: %{
          "content-type" => "application/json",
          "user-agent" => "Postmark",
          "authorization" => "Basic cG9zdG1hcmtfdXNlcjpwb3N0bWFya19wYXNz"
        }
      },
      body: %{
        "MessageID" => "883953f4-6105-42a2-a16a-77a8eac79483",
        "Recipient" => "john@example.com",
        "DeliveredAt" => "2019-11-05T16:33:54.9070259Z",
        "Details" => "Test delivery webhook details",
        "Tag" => "welcome-email",
        "ServerID" => 23,
        "Metadata" => %{"a_key" => "a_value", "b_key" => "b_value"},
        "RecordType" => "Delivery",
        "MessageStream" => "outbound"
      }
    }
  end

  @doc """
  MailerSend delivered activity webhook.

  Sources:

    * https://developers.mailersend.com/api/v1/webhooks
    * https://developers.mailersend.com/guides/setting-up-webhooks
  """
  def mailersend_delivered do
    raw_body =
      ~s({"type":"activity.delivered","created_at":"2026-05-06T14:12:33.000000Z","data":{"id":"6892766a5b66e2daf3dc9155","domain_id":"yv69oxl5kl785kw2","message_id":"6892766ae78995a317577aa1","email_id":"6892766a8d52ba62543d5e71","type":"delivered","subject":"Receipt #1234","email":"customer@example.com","tags":["receipt","production"],"meta":{"order_id":"ord_1234"}}})

    %{
      provider: :mailersend,
      signing_secret: "whsec_test_123",
      headers: %{
        "content-type" => "application/json",
        "signature" => "52f62c6551afbfeb693f261fce07145dc64bc30d9118f4c4403c922984aa76f1"
      },
      raw_body: raw_body,
      body: Jason.decode!(raw_body)
    }
  end

  @doc """
  Amazon SES delivery notification wrapped in an SNS Notification.

  Sources:

    * https://docs.aws.amazon.com/ses/latest/dg/notification-examples.html
    * https://docs.aws.amazon.com/sns/latest/dg/http-notification-json.html
    * https://docs.aws.amazon.com/sns/latest/dg/sns-verify-signature-of-message.html
  """
  def ses_delivery do
    inner =
      Jason.encode!(%{
        "notificationType" => "Delivery",
        "mail" => %{
          "timestamp" => "2026-05-06T14:31:10.000Z",
          "messageId" => "0000018f4b0d9abc-11111111-2222-3333-4444-555555555555-000000",
          "source" => "sender@example.com",
          "destination" => ["recipient@example.net"]
        },
        "delivery" => %{
          "timestamp" => "2026-05-06T14:31:12.000Z",
          "recipients" => ["recipient@example.net"],
          "processingTimeMillis" => 546,
          "smtpResponse" => "250 ok: Message accepted",
          "reportingMTA" => "a8-70.smtp-out.amazonses.com"
        }
      })

    %{
      headers: %{
        "content-type" => "text/plain; charset=UTF-8",
        "x-amz-sns-message-type" => "Notification",
        "x-amz-sns-message-id" => "22b80b92-fdea-4c2c-8f9d-bdfb0c7bf324",
        "x-amz-sns-topic-arn" => "arn:aws:sns:us-east-1:123456789012:ses-events"
      },
      body: %{
        "Type" => "Notification",
        "MessageId" => "22b80b92-fdea-4c2c-8f9d-bdfb0c7bf324",
        "TopicArn" => "arn:aws:sns:us-east-1:123456789012:ses-events",
        "Subject" => "Amazon SES Notification",
        "Message" => inner,
        "Timestamp" => "2026-05-06T14:31:13.000Z",
        "SignatureVersion" => "2",
        "Signature" => "BASE64_RSA_SHA256_SIGNATURE",
        "SigningCertURL" =>
          "https://sns.us-east-1.amazonaws.com/SimpleNotificationService-0123456789abcdef.pem",
        "UnsubscribeURL" =>
          "https://sns.us-east-1.amazonaws.com/?Action=Unsubscribe&SubscriptionArn=..."
      }
    }
  end

  @doc """
  Twilio delivered status callback with a valid sample signature.

  Sources:

    * https://www.twilio.com/docs/messaging/api/message-resource
    * https://www.twilio.com/docs/messaging/guides/track-outbound-message-status
    * https://www.twilio.com/docs/usage/security
  """
  def twilio_delivered_status do
    %{
      headers: %{
        "content-type" => "application/x-www-form-urlencoded",
        "x-twilio-signature" => "7nVA4EkMCadw20HuNyPB7Jisq84="
      },
      url: "https://example.com/twilio/status",
      form: %{
        "AccountSid" => "AC11111111111111111111111111111111",
        "From" => "+15017122661",
        "To" => "+15558675310",
        "MessageSid" => "SM22222222222222222222222222222222",
        "SmsSid" => "SM22222222222222222222222222222222",
        "MessageStatus" => "delivered",
        "SmsStatus" => "delivered",
        "RawDlrDoneDate" => "2605061432"
      }
    }
  end
end
