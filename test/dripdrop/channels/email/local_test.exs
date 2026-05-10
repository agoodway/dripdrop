defmodule DripDrop.Channels.Email.LocalTest do
  use ExUnit.Case, async: true

  alias DripDrop.{ChannelAdapter, Channels, Enrollment, Step}
  alias DripDrop.Channels.Email.Local

  describe "provider registration" do
    test "is available as the built-in local email provider" do
      assert :local in Channels.providers(:email)
      assert {:ok, Local} = Channels.provider_module(:email, :local)
    end
  end

  describe "deliver/3" do
    test "builds a Swoosh email through the local provider path" do
      adapter =
        adapter_struct(%{
          credentials: %{"from" => "team@example.com"},
          config: %{provider_options: [adapter: Swoosh.Adapters.Test]}
        })

      assert {:ok, %{response: %{result: %{}}}} =
               Local.deliver(basic_email_step(), enrollment_struct(), adapter)

      assert_receive {:email, %Swoosh.Email{} = email}

      assert email.from == {"", "team@example.com"}
      assert email.to == [{"", "ada@example.com"}]
      assert email.subject == "Welcome"
      assert email.text_body == "Hello"
      assert email.html_body == "<p>Hello</p>"
    end

    test "normalizes display-name mailbox credentials for the Swoosh preview" do
      adapter =
        adapter_struct(%{
          credentials: %{"from" => "DripDrop Demo <hello@dripdrop.local>"},
          config: %{provider_options: [adapter: Swoosh.Adapters.Test]}
        })

      assert {:ok, %{response: %{result: %{}}}} =
               Local.deliver(basic_email_step(), enrollment_struct(), adapter)

      assert_receive {:email, %Swoosh.Email{} = email}

      assert email.from == {"DripDrop Demo", "hello@dripdrop.local"}
    end
  end

  defp adapter_struct(attrs) do
    base = %{
      id: Ecto.UUID.generate(),
      name: "Local email fixture",
      tenant_key: "tenant-a",
      channel: "email",
      provider: "local",
      credentials: %{},
      config: %{},
      active: true
    }

    struct!(ChannelAdapter, Map.merge(base, attrs))
  end

  defp basic_email_step do
    struct!(Step, %{
      channel: "email",
      key: "local-email-step",
      config: %{
        "payload" => %{
          "to" => "ada@example.com",
          "subject" => "Welcome",
          "text" => "Hello",
          "html" => "<p>Hello</p>"
        }
      },
      template_content: %{}
    })
  end

  defp enrollment_struct do
    struct!(Enrollment, %{
      tenant_key: "tenant-a",
      subscriber_type: "user",
      subscriber_id: "ada",
      data: %{"email" => "ada@example.com"}
    })
  end
end
