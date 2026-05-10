defmodule DripDrop.Channels.SMS.LocalTest do
  use ExUnit.Case, async: true

  alias DripDrop.{ChannelAdapter, Channels, Enrollment, Step}
  alias DripDrop.Channels.SMS.Local

  describe "provider registration" do
    test "is available as the built-in local SMS provider" do
      assert :local in Channels.providers(:sms)
      assert {:ok, Local} = Channels.provider_module(:sms, :local)
    end
  end

  describe "deliver/3" do
    test "returns a synthetic local result without external IO" do
      assert {:ok, result} = Local.deliver(sms_step(), enrollment_struct(), adapter_struct())

      assert result.provider_message_id =~ "local-sms-"

      assert result.response == %{
               provider: "local",
               to: "+15551234567",
               from: "+15557654321",
               body: "Hello from DripDrop"
             }
    end
  end

  defp adapter_struct do
    struct!(ChannelAdapter, %{
      id: Ecto.UUID.generate(),
      name: "Local SMS fixture",
      tenant_key: "tenant-a",
      channel: "sms",
      provider: "local",
      credentials: %{"from" => "+15557654321"},
      config: %{},
      active: true
    })
  end

  defp sms_step do
    struct!(Step, %{
      channel: "sms",
      key: "local-sms-step",
      config: %{"payload" => %{"body" => "Hello from DripDrop"}},
      template_content: %{}
    })
  end

  defp enrollment_struct do
    struct!(Enrollment, %{
      tenant_key: "tenant-a",
      subscriber_type: "user",
      subscriber_id: "ada",
      data: %{"sms" => "+15551234567"}
    })
  end
end
