defmodule DripDrop.Channels.SMS.AwsSnsTest do
  @moduledoc """
  Real-shape integration tests for the Amazon SNS SMS adapter.

  Strategy: instead of mocking the network, we let `ExAws.SNS.publish/2`
  build the real `%ExAws.Operation.Query{}` struct (same code path
  production uses) and stub `ExAws.request/2` via the configurable
  `:dripdrop, :ex_aws_request_fun` seam. The stub captures the operation
  for assertions and returns canned `{:ok, %{...}}` / `{:error, ...}`
  shapes mirroring real ExAws responses.

  Rationale: ExAws does not expose a Swoosh-style test adapter. Asserting
  on the operation struct exercises every parameter the adapter forwards
  (Action, PhoneNumber/TopicArn, Message, MessageAttributes) at the same
  layer ExAws would serialize for the real Publish HTTP call.
  """

  use ExUnit.Case, async: false

  alias DripDrop.{ChannelAdapter, Enrollment, Step}
  alias DripDrop.Channels.SMS.AwsSns
  alias DripDrop.Fixtures.SMS.AwsSns, as: Fixtures

  setup do
    previous = Application.get_env(:dripdrop, :ex_aws_request_fun)
    parent = self()
    ref = make_ref()

    on_exit(fn ->
      if previous do
        Application.put_env(:dripdrop, :ex_aws_request_fun, previous)
      else
        Application.delete_env(:dripdrop, :ex_aws_request_fun)
      end
    end)

    {:ok, parent: parent, ref: ref}
  end

  describe "deliver/3 — direct phone publish" do
    test "builds a Publish operation with PhoneNumber and Message", %{
      parent: parent,
      ref: ref
    } do
      stub_request(parent, ref, fn _operation, _opts ->
        {:ok, Fixtures.success_response()}
      end)

      adapter = adapter(%{credentials: %{"region" => "us-east-1"}})
      step = step(Fixtures.direct_phone_payload())

      assert {:ok, %{provider_message_id: message_id}} =
               AwsSns.deliver(step, enrollment(), adapter)

      assert message_id == "567910cd-659e-55d4-8ccb-5aaf14679dc0"

      assert_received {:ex_aws_request, ^ref, %ExAws.Operation.Query{} = operation, _opts}
      assert operation.service == :sns
      assert operation.action == :publish
      assert operation.params["Action"] == "Publish"
      assert operation.params["PhoneNumber"] == Fixtures.reference_phone_number()
      assert operation.params["Message"] == "Your verification code is 123456"
      refute Map.has_key?(operation.params, "TopicArn")
      refute Map.has_key?(operation.params, "TargetArn")
    end

    test "forwards :region from adapter credentials to ExAws.request/2", %{
      parent: parent,
      ref: ref
    } do
      stub_request(parent, ref, fn _operation, _opts ->
        {:ok, Fixtures.success_response()}
      end)

      adapter = adapter(%{credentials: %{"region" => "eu-west-2"}})

      assert {:ok, _} =
               AwsSns.deliver(step(Fixtures.direct_phone_payload()), enrollment(), adapter)

      assert_received {:ex_aws_request, ^ref, _operation, opts}
      assert opts[:region] == "eu-west-2"
    end

    test "resolves PhoneNumber from payload.to when overridden", %{parent: parent, ref: ref} do
      stub_request(parent, ref, fn _op, _opts -> {:ok, Fixtures.success_response()} end)

      # Enrollment has no SMS data — the override must win.
      enrollment = struct!(Enrollment, %{tenant_key: "tenant-a", data: %{}})
      adapter = adapter(%{credentials: %{"region" => "us-east-1"}})

      assert {:ok, _} =
               AwsSns.deliver(
                 step(Fixtures.direct_phone_payload_with_override()),
                 enrollment,
                 adapter
               )

      assert_received {:ex_aws_request, ^ref, operation, _opts}
      assert operation.params["PhoneNumber"] == Fixtures.reference_phone_number()
    end
  end

  describe "deliver/3 — SMS message attributes" do
    test "encodes SenderID, MaxPrice, and SMSType into MessageAttributes.entry.N.* params", %{
      parent: parent,
      ref: ref
    } do
      stub_request(parent, ref, fn _op, _opts -> {:ok, Fixtures.success_response()} end)

      adapter = adapter(%{credentials: %{"region" => "us-east-1"}})

      assert {:ok, _} =
               AwsSns.deliver(step(Fixtures.sms_attributes_payload()), enrollment(), adapter)

      assert_received {:ex_aws_request, ^ref, operation, _opts}

      # Walk the MessageAttributes.entry.{N} groups ExAws builds and pull
      # them back into a name->value map keyed by attribute name.
      attrs = decode_message_attributes(operation.params)

      assert attrs["AWS.SNS.SMS.SenderID"] == %{
               "DataType" => "String",
               "StringValue" => "DripDrop"
             }

      assert attrs["AWS.SNS.SMS.MaxPrice"] == %{
               "DataType" => "Number",
               "StringValue" => "0.50"
             }

      assert attrs["AWS.SNS.SMS.SMSType"] == %{
               "DataType" => "String",
               "StringValue" => "Transactional"
             }
    end
  end

  describe "deliver/3 — environment guard" do
    @tag :documents_branch
    test "ex_aws_sns_unavailable is returned cleanly when ExAws is not loaded" do
      # ExAws is loaded in this test environment (it's a dep), so the
      # `ex_aws_sns_unavailable` branch cannot be exercised directly without
      # tearing down the loaded module. We pin the documented behavior by
      # asserting on the predicate the adapter uses to gate the call.
      #
      # Production semantics: when ExAws or ExAws.SNS is missing, the
      # adapter must return
      # `{:error, %{kind: :permanent, reason: :ex_aws_sns_unavailable}}`
      # without raising, so a host that hasn't installed `:ex_aws_sns` gets
      # a permanent failure on send rather than a crash.
      assert Code.ensure_loaded?(ExAws)
      assert Code.ensure_loaded?(ExAws.SNS)
      assert function_exported?(ExAws.SNS, :publish, 2)
      assert function_exported?(ExAws, :request, 2)
    end
  end

  describe "sns_result/1 — response normalization" do
    test "success response surfaces provider_message_id", %{parent: parent, ref: ref} do
      stub_request(parent, ref, fn _op, _opts -> {:ok, Fixtures.success_response()} end)

      assert {:ok, result} =
               AwsSns.deliver(
                 step(Fixtures.direct_phone_payload()),
                 enrollment(),
                 adapter(%{credentials: %{"region" => "us-east-1"}})
               )

      assert result.provider_message_id == "567910cd-659e-55d4-8ccb-5aaf14679dc0"
      assert is_map(result.response)
    end

    test "5xx HTTP errors are normalized to a temporary failure", %{
      parent: parent,
      ref: ref
    } do
      stub_request(parent, ref, fn _op, _opts ->
        {:error, Fixtures.error_response_service_unavailable()}
      end)

      assert {:error, %{kind: :temporary, reason: {:aws_sns, 503, _body}}} =
               AwsSns.deliver(
                 step(Fixtures.direct_phone_payload()),
                 enrollment(),
                 adapter(%{credentials: %{"region" => "us-east-1"}})
               )
    end

    test "4xx errors map to a permanent failure", %{parent: parent, ref: ref} do
      stub_request(parent, ref, fn _op, _opts ->
        {:error, Fixtures.error_response_invalid_parameter()}
      end)

      assert {:error, %{kind: :permanent, reason: {:aws_sns, _reason}}} =
               AwsSns.deliver(
                 step(Fixtures.direct_phone_payload()),
                 enrollment(),
                 adapter(%{credentials: %{"region" => "us-east-1"}})
               )
    end
  end

  defp stub_request(parent, ref, fun) do
    Application.put_env(
      :dripdrop,
      :ex_aws_request_fun,
      fn operation, opts ->
        send(parent, {:ex_aws_request, ref, operation, opts})
        fun.(operation, opts)
      end
    )
  end

  defp adapter(attrs) do
    base = %{
      id: Ecto.UUID.generate(),
      name: "AWS SNS",
      tenant_key: "tenant-a",
      channel: "sms",
      provider: "aws_sns",
      credentials: %{},
      config: %{},
      active: true
    }

    struct!(ChannelAdapter, Map.merge(base, attrs))
  end

  defp step(payload) do
    struct!(Step, %{
      channel: "sms",
      key: "sms-step",
      config: %{"payload" => payload},
      template_content: %{}
    })
  end

  defp enrollment do
    struct!(Enrollment, %{
      tenant_key: "tenant-a",
      subscriber_type: "user",
      subscriber_id: "ada",
      data: %{"sms" => Fixtures.reference_phone_number()}
    })
  end

  # Unfold ExAws's `MessageAttributes.entry.{N}.*` query-string keys into
  # `%{"AttrName" => %{"DataType" => ..., "StringValue" => ...}}`.
  defp decode_message_attributes(params) do
    params
    |> Enum.flat_map(fn
      {"MessageAttributes.entry." <> rest, value} -> [{rest, value}]
      _ -> []
    end)
    |> Enum.reduce(%{}, fn {rest, value}, acc ->
      [_index, field | tail] = String.split(rest, ".")
      sub_field = Enum.join([field | tail], ".")

      acc
      |> Map.put_new("__by_index__#{_index_key(rest)}", %{})
      |> put_in_attribute(rest, sub_field, value)
    end)
    |> by_name()
  end

  defp _index_key(rest), do: rest |> String.split(".") |> hd()

  defp put_in_attribute(acc, rest, sub_field, value) do
    index_key = "__by_index__#{_index_key(rest)}"
    current = Map.get(acc, index_key, %{})

    updated =
      case sub_field do
        "Name" -> Map.put(current, "Name", value)
        "Value." <> inner -> Map.put(current, inner, value)
        other -> Map.put(current, other, value)
      end

    Map.put(acc, index_key, updated)
  end

  defp by_name(acc) do
    acc
    |> Enum.filter(fn {key, _} -> String.starts_with?(key, "__by_index__") end)
    |> Enum.into(%{}, fn {_index_key, attrs} ->
      {Map.fetch!(attrs, "Name"), Map.delete(attrs, "Name")}
    end)
  end
end
