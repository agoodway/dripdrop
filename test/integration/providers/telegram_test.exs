defmodule DripDrop.Integration.Providers.TelegramTest do
  use DripDrop.DataCase, async: false

  @moduletag :integration

  alias DripDrop.{ChannelAdapter, Enrollment, Step}
  alias DripDrop.Channels.Telegram.BotAPI

  test "posts bot API sendMessage payload shape" do
    stub_req(fn conn ->
      assert conn.request_path == "/botbot-token/sendMessage"
      assert json_body(conn) == %{"chat_id" => "chat-1", "text" => "Hello Telegram"}

      Req.Test.json(conn, %{"ok" => true, "result" => %{"message_id" => 123}})
    end)

    assert {:ok, %{provider_message_id: "123", response: %{"message_id" => 123}}} =
             BotAPI.deliver(
               step("telegram", %{text: "Hello Telegram"}),
               enrollment(),
               adapter(%{
                 channel: "telegram",
                 provider: "bot_api",
                 credentials: %{"bot_token" => "bot-token", "chat_id" => "chat-1"}
               })
             )
  end

  defp adapter(attrs) do
    struct!(
      ChannelAdapter,
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          name: "Telegram",
          tenant_key: "tenant-a",
          credentials: %{},
          config: %{},
          active: true
        },
        attrs
      )
    )
  end

  defp step(channel, payload) do
    struct!(Step, %{
      channel: channel,
      key: "#{channel}-step",
      config: %{"payload" => payload},
      template_content: %{}
    })
  end

  defp enrollment do
    struct!(Enrollment, %{
      tenant_key: "tenant-a",
      subscriber_type: "user",
      subscriber_id: "ada",
      data: %{}
    })
  end

  defp stub_req(fun) do
    previous = Application.get_env(:dripdrop, :channel_req_options)
    name = :"telegram-provider-#{System.unique_integer([:positive])}"

    Req.Test.stub(name, fun)
    Application.put_env(:dripdrop, :channel_req_options, plug: {Req.Test, name})
    on_exit(fn -> Application.put_env(:dripdrop, :channel_req_options, previous) end)
  end

  defp json_body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(body)
  end
end
