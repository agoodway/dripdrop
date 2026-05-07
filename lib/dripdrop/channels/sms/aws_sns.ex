defmodule DripDrop.Channels.SMS.AwsSns do
  @moduledoc """
  Amazon SNS SMS provider.
  """

  use DripDrop.Channels.Provider, required_credentials: [:region]

  alias DripDrop.Channels.{Helpers, Payload}

  @impl DripDrop.Channel
  def deliver(step, enrollment, adapter) do
    if ex_aws_sns_available?() do
      do_deliver(step, enrollment, adapter)
    else
      {:error, %{kind: :permanent, reason: :ex_aws_sns_unavailable}}
    end
  end

  defp do_deliver(step, enrollment, adapter) do
    payload = Payload.get(step)
    message = Map.get(payload, :body)
    phone_number = Helpers.recipient(enrollment, payload, :sms)
    region = Helpers.credential(adapter, :region)
    opts = publish_opts(payload, phone_number)

    message
    |> ExAws.SNS.publish(opts)
    |> request(region: region)
    |> sns_result()
  end

  defp publish_opts(payload, phone_number) do
    [
      phone_number: phone_number,
      message_attributes: message_attributes(payload)
    ]
  end

  # Configurable request seam — tests can replace this with a stub via
  # `Application.put_env(:dripdrop, :ex_aws_request_fun, &MyStub.request/2)`
  # to assert on the built `%ExAws.Operation.Query{}` and return a canned
  # response without performing a network call.
  defp request(operation, opts) do
    request_fun = Application.get_env(:dripdrop, :ex_aws_request_fun, &ExAws.request/2)
    request_fun.(operation, opts)
  end

  defp ex_aws_sns_available? do
    Code.ensure_loaded?(ExAws) and Code.ensure_loaded?(ExAws.SNS) and
      function_exported?(ExAws.SNS, :publish, 2) and function_exported?(ExAws, :request, 2)
  end

  defp message_attributes(payload) do
    payload
    |> Map.get(:message_attributes, [])
    |> Enum.map(fn
      %{name: name, data_type: data_type, value: value} ->
        %{name: name, data_type: data_type, value: value}

      %{"name" => name, "data_type" => data_type, "value" => value} ->
        %{name: name, data_type: data_type, value: value}
    end)
  end

  defp sns_result({:ok, %{body: %{message_id: message_id}} = response}) do
    {:ok, %{provider_message_id: message_id, response: response_to_map(response)}}
  end

  defp sns_result({:ok, %{body: %{"MessageId" => message_id}} = response}) do
    {:ok, %{provider_message_id: message_id, response: response_to_map(response)}}
  end

  defp sns_result({:ok, response}) do
    {:ok, %{provider_message_id: nil, response: response_to_map(response)}}
  end

  defp sns_result({:error, {:http_error, status, body}})
       when status in 500..599 or status == 429 do
    {:error, %{kind: :temporary, reason: {:aws_sns, status, body}}}
  end

  defp sns_result({:error, reason}), do: {:error, %{kind: :permanent, reason: {:aws_sns, reason}}}

  defp response_to_map(%_struct{} = response), do: Map.from_struct(response)
  defp response_to_map(response) when is_map(response), do: response
  defp response_to_map(response), do: %{response: response}
end
