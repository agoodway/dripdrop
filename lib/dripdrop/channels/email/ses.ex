defmodule DripDrop.Channels.Email.SES do
  @moduledoc """
  Amazon SES email provider backed by Swoosh.

  The provider sends through `Swoosh.Adapters.AmazonSES` and declares the SES
  SNS webhook route used by the event-ingestion layer. Inbound notifications
  are verified with Amazon SNS certificate signatures before persistence.
  """

  use DripDrop.Channels.Provider,
    required_credentials: [:region, :access_key, :secret, :sns_topic_arn]

  alias DripDrop.Cache
  alias DripDrop.Channels.Email.SES.WebhookHandler
  alias DripDrop.Channels.Email.SwooshDelivery
  alias DripDrop.Channels.Helpers
  alias DripDrop.WebhookRequest

  @cert_cache_ttl :timer.hours(1)
  @cert_fetch_timeout 5_000

  @impl DripDrop.Channel
  def deliver(step, enrollment, adapter) do
    config =
      SwooshDelivery.config(adapter, Swoosh.Adapters.AmazonSES, [
        :region,
        :access_key,
        :secret,
        :host
      ])

    SwooshDelivery.deliver(step, enrollment, adapter, config)
  end

  @impl DripDrop.Channel
  def webhook_routes(_adapter),
    do: [{:post, "/ses/:adapter_id", WebhookHandler}]

  @impl DripDrop.Channel
  def verify_signature(adapter, request) do
    expected_topic = Helpers.credential(adapter, :sns_topic_arn)

    with {:ok, message} <- Jason.decode(WebhookRequest.body(request)),
         :ok <- validate_topic(message["TopicArn"], expected_topic),
         :ok <- check_replay_window(message["Timestamp"], adapter),
         :ok <- validate_cert_url(message["SigningCertURL"]),
         {:ok, certificate} <- fetch_certificate(message["SigningCertURL"]),
         {:ok, signature} <- Base.decode64(message["Signature"] || ""),
         true <- verify_sns_signature(message, signature, certificate) do
      :ok
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_signature}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_signature}
    end
  end

  defp check_replay_window(timestamp, adapter) do
    if Helpers.within_skew?(timestamp, replay_skew_seconds()) do
      :ok
    else
      :telemetry.execute([:dripdrop, :webhook, :replay_window], %{count: 1}, %{
        provider: :ses,
        adapter_id: Map.get(adapter, :id),
        timestamp: timestamp
      })

      {:error, :replay_window}
    end
  end

  defp replay_skew_seconds,
    do: Application.get_env(:dripdrop, :webhook_replay_skew_seconds, 300)

  defp validate_topic(_topic_arn, nil), do: {:error, :sns_topic_arn_required}
  defp validate_topic(topic_arn, topic_arn), do: :ok
  defp validate_topic(_topic_arn, _expected_topic), do: {:error, :topic_mismatch}

  defp validate_cert_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme == "https" and
         String.ends_with?(uri.host || "", ".amazonaws.com") and
         String.starts_with?(uri.path || "", "/SimpleNotificationService-") do
      :ok
    else
      {:error, :invalid_cert_url}
    end
  end

  defp validate_cert_url(_url), do: {:error, :invalid_cert_url}

  defp fetch_certificate(url) do
    cache_key = {__MODULE__, :sns_cert, url}

    case Cache.get(cache_key) do
      {:ok, cert} when not is_nil(cert) ->
        {:ok, cert}

      _miss ->
        case do_fetch_certificate(url) do
          {:ok, cert} ->
            Cache.put(cache_key, cert, ttl: @cert_cache_ttl)
            {:ok, cert}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp do_fetch_certificate(url) do
    case Req.get(url, receive_timeout: @cert_fetch_timeout) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        [{:Certificate, der, _metadata}] = :public_key.pem_decode(body)
        {:ok, :public_key.pkix_decode_cert(der, :otp)}

      _error ->
        {:error, :cert_fetch_failed}
    end
  rescue
    MatchError -> {:error, :invalid_certificate}
  end

  defp verify_sns_signature(message, signature, certificate) do
    algorithm =
      case message["SignatureVersion"] do
        "2" -> :sha256
        _version -> :sha
      end

    :public_key.verify(canonical_message(message), algorithm, signature, certificate)
  end

  defp canonical_message(%{"Type" => "Notification"} = message) do
    [
      {"Message", message["Message"]},
      {"MessageId", message["MessageId"]},
      {"Subject", message["Subject"]},
      {"Timestamp", message["Timestamp"]},
      {"TopicArn", message["TopicArn"]},
      {"Type", message["Type"]}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.map_join("", fn {key, value} -> "#{key}\n#{value}\n" end)
  end

  defp canonical_message(%{"Type" => "SubscriptionConfirmation"} = message) do
    [
      {"Message", message["Message"]},
      {"MessageId", message["MessageId"]},
      {"SubscribeURL", message["SubscribeURL"]},
      {"Timestamp", message["Timestamp"]},
      {"Token", message["Token"]},
      {"TopicArn", message["TopicArn"]},
      {"Type", message["Type"]}
    ]
    |> Enum.map_join("", fn {key, value} -> "#{key}\n#{value}\n" end)
  end

  defp canonical_message(message), do: canonical_message(Map.put(message, "Type", "Notification"))
end
