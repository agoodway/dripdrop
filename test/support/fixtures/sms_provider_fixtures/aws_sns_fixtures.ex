defmodule DripDrop.Fixtures.SMS.AwsSns do
  @moduledoc """
  Real-shape fixtures for Amazon SNS `Publish` action requests and responses.

  Captured from the official AWS SNS API reference as of 2026-05-07.

  Sources:
    * https://docs.aws.amazon.com/sns/latest/api/API_Publish.html
    * https://docs.aws.amazon.com/sns/latest/dg/sms_publish-to-phone.html
    * https://docs.aws.amazon.com/sns/latest/dg/sms_publish-to-phone.html#sms_publish_sdk
    * https://docs.aws.amazon.com/sns/latest/dg/channels-sms-publish.html
    * https://docs.aws.amazon.com/sns/latest/api/CommonErrors.html
    * https://hexdocs.pm/ex_aws_sns/ExAws.SNS.html#publish/2

  These fixtures are reference values: tests assert against them so any drift
  in the documented contract surfaces as a clear test failure rather than a
  silent breakage in production.

  ## Publish action overview

  The SNS `Publish` action accepts the following query-string parameters
  (encoded by `ExAws.Operation.Query`):

    * `Action=Publish` — required
    * Exactly one of `PhoneNumber`, `TopicArn`, or `TargetArn`
    * `Message` — required, the SMS body
    * `MessageAttributes.entry.{N}.Name` — attribute name
    * `MessageAttributes.entry.{N}.Value.DataType` — `String`, `Number`,
      `Binary`, or `String.Array`
    * `MessageAttributes.entry.{N}.Value.StringValue` (or `BinaryValue`)

  ## Critical SMS message attributes

  Documented at
  https://docs.aws.amazon.com/sns/latest/dg/sms_publish-to-phone.html#sms_publish_sdk:

    * `AWS.SNS.SMS.SenderID` — alphanumeric originator (where supported)
    * `AWS.SNS.SMS.MaxPrice` — maximum price per message in USD
    * `AWS.SNS.SMS.SMSType` — `Promotional` (default) or `Transactional`
  """

  @doc """
  E.164 reference phone number used across the SMS fixtures.
  """
  def reference_phone_number, do: "+15551234567"

  @doc """
  Reference topic ARN used for the topic-publish path.
  """
  def reference_topic_arn, do: "arn:aws:sns:us-east-1:111111111111:dripdrop-broadcast"

  @doc """
  Direct-to-phone publish payload (DripDrop step payload shape).

  Resolves through `Helpers.recipient/3` from `enrollment.data["sms"]`, so
  callers do not have to set `:to` explicitly. This represents the most
  common SMS path: send a transactional message to a single E.164 number.
  """
  def direct_phone_payload do
    %{
      body: "Your verification code is 123456"
    }
  end

  @doc """
  Direct-to-phone publish payload with the recipient overridden in the step
  payload (`payload.to`). Mirrors how an authoring layer can target a
  specific number without enrollment data.
  """
  def direct_phone_payload_with_override do
    %{
      body: "Your verification code is 123456",
      to: reference_phone_number()
    }
  end

  @doc """
  Publish payload carrying the documented SMS-specific message attributes.

  ExAws.SNS encodes these into `MessageAttributes.entry.{N}.{Name|Value.*}`
  query-string parameters; the test asserts on the encoded shape.
  """
  def sms_attributes_payload do
    %{
      body: "Sale ends tonight!",
      to: reference_phone_number(),
      message_attributes: [
        %{
          name: "AWS.SNS.SMS.SenderID",
          data_type: :string,
          value: {:string, "DripDrop"}
        },
        %{
          name: "AWS.SNS.SMS.MaxPrice",
          data_type: :number,
          value: {:string, "0.50"}
        },
        %{
          name: "AWS.SNS.SMS.SMSType",
          data_type: :string,
          value: {:string, "Transactional"}
        }
      ]
    }
  end

  @doc """
  Topic-arn publish payload (broadcast to subscribers of a topic).
  """
  def topic_payload do
    %{
      body: "Cluster failover initiated",
      topic_arn: reference_topic_arn()
    }
  end

  @doc """
  Successful `Publish` response shape — what `ExAws.SNS.Parsers.parse/2`
  returns after parsing the documented SNS XML envelope.

  Reference XML envelope (https://docs.aws.amazon.com/sns/latest/api/API_Publish.html):

      <PublishResponse xmlns="http://sns.amazonaws.com/doc/2010-03-31/">
        <PublishResult>
          <MessageId>567910cd-659e-55d4-8ccb-5aaf14679dc0</MessageId>
        </PublishResult>
        <ResponseMetadata>
          <RequestId>d74b8436-ae13-5ab4-a9ff-ce54dfea72a0</RequestId>
        </ResponseMetadata>
      </PublishResponse>
  """
  def success_response do
    %{
      status_code: 200,
      body: %{
        message_id: "567910cd-659e-55d4-8ccb-5aaf14679dc0",
        request_id: "d74b8436-ae13-5ab4-a9ff-ce54dfea72a0"
      }
    }
  end

  @doc """
  Raw Publish XML response body — useful for documentation and for tests
  that want to exercise the parser end-to-end.
  """
  def success_response_xml do
    """
    <PublishResponse xmlns="http://sns.amazonaws.com/doc/2010-03-31/">
      <PublishResult>
        <MessageId>567910cd-659e-55d4-8ccb-5aaf14679dc0</MessageId>
      </PublishResult>
      <ResponseMetadata>
        <RequestId>d74b8436-ae13-5ab4-a9ff-ce54dfea72a0</RequestId>
      </ResponseMetadata>
    </PublishResponse>
    """
  end

  @doc """
  Error envelope shape ExAws returns from a 4xx/5xx response.

  Reference XML envelope (https://docs.aws.amazon.com/sns/latest/api/CommonErrors.html):

      <ErrorResponse xmlns="http://sns.amazonaws.com/doc/2010-03-31/">
        <Error>
          <Type>Sender</Type>
          <Code>InvalidParameter</Code>
          <Message>Invalid parameter: PhoneNumber Reason: ...</Message>
        </Error>
        <RequestId>...</RequestId>
      </ErrorResponse>
  """
  def error_response_invalid_parameter do
    {:http_error, 400,
     %{
       code: "InvalidParameter",
       message: "Invalid parameter: PhoneNumber Reason: not a valid phone number",
       request_id: "00000000-0000-0000-0000-000000000000",
       type: "Sender"
     }}
  end

  @doc """
  Server-side error envelope (500–599 / 429) treated as transient by the
  adapter.
  """
  def error_response_service_unavailable do
    {:http_error, 503,
     %{
       code: "ServiceUnavailable",
       message: "Service is unavailable. Try again later.",
       type: "Server"
     }}
  end
end
