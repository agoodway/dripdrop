defmodule DripDrop.Integration.Providers.SlackTest do
  use DripDrop.DataCase, async: false

  @moduletag :integration

  alias DripDrop.{ChannelAdapter, Enrollment, Step}
  alias DripDrop.Channels.Slack.Webhook

  test "posts incoming webhook payload shape and registers no inbound routes" do
    stub_req(fn conn ->
      assert conn.request_path == "/slack"
      assert json_body(conn) == %{"text" => "Build shipped", "blocks" => [%{"type" => "section"}]}

      Req.Test.json(conn, %{"ok" => true})
    end)

    adapter =
      adapter(%{
        channel: "slack",
        provider: "webhook",
        credentials: %{"url" => "https://hooks.slack.example.com/slack"}
      })

    assert {:ok, %{provider_message_id: nil, response: %{status: 200}}} =
             Webhook.deliver(
               step("slack", %{text: "Build shipped", blocks: [%{type: "section"}]}),
               enrollment(),
               adapter
             )

    assert Webhook.webhook_routes(adapter) == []
  end

  defp adapter(attrs) do
    struct!(
      ChannelAdapter,
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          name: "Slack",
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
    name = :"slack-provider-#{System.unique_integer([:positive])}"

    Req.Test.stub(name, fun)
    Application.put_env(:dripdrop, :channel_req_options, plug: {Req.Test, name})
    on_exit(fn -> Application.put_env(:dripdrop, :channel_req_options, previous) end)
  end

  defp json_body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(body)
  end
end
