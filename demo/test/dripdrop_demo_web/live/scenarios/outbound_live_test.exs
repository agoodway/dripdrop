defmodule DripdropDemoWeb.Scenarios.OutboundLiveTest do
  use DripdropDemoWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias DripDrop.{MessageEvent, Suppression}
  alias DripdropDemo.Repo
  alias DripdropDemo.Scenarios.Outbound
  alias DripdropDemo.Test.OutboundFixture

  setup do
    OutboundFixture.seed_outbound_minimal()
    :ok
  end

  test "renders the prospect grid after enrollment", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/scenarios/outbound")

    html =
      view
      |> element("button", "Outbound Campaign")
      |> render_click()

    for first_name <- ~w(Mia Jordan Priya Eli Nora Theo Avery Quinn) do
      assert html =~ first_name
    end

    assert html =~ "Sender pool"
    refute html =~ "Auto-play"
    refute html =~ "Trigger outcome"
  end

  test "campaign outcome timer runs simulator and refreshes rendered state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/scenarios/outbound")

    view
    |> element("button", "Outbound Campaign")
    |> render_click()

    eli_id = enrollment_id_for(view, "Eli")
    assert is_binary(eli_id), "expected to find Eli's enrollment id in the rendered grid"

    send(view.pid, {:autoplay_outcome, eli_id})
    html = render(view)

    assert html =~ "Hard bounce"

    assert Repo.exists?(
             from(event in MessageEvent,
               where: event.event_type == "bounced",
               where: event.event_data["severity"] == "permanent"
             )
           )

    assert Repo.exists?(
             from(suppression in Suppression,
               where: suppression.recipient_normalized == "eli@runway.example",
               where: suppression.reason == "bounce"
             )
           )
  end

  test "health PubSub events refresh the sender pool panel", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/scenarios/outbound")
    [member | _members] = Outbound.list_pool_members()

    {:ok, _adapter} =
      DripDrop.set_adapter_health(member.id, %{
        health_state: :resting,
        resting_until: DateTime.add(DateTime.utc_now(:second), 60, :second),
        source: "test"
      })

    Phoenix.PubSub.broadcast(
      DripdropDemo.PubSub,
      "adapter:#{member.id}",
      {:dripdrop_event, [:dripdrop, :health, :state_changed], %{count: 1},
       %{adapter_id: member.id}}
    )

    assert render(view) =~ "resting"
  end

  test "reset capacity button refreshes the sender pool state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/scenarios/outbound")

    html =
      view
      |> element("button", "Reset capacity")
      |> render_click()

    assert html =~ "Sender capacity reset"
    assert html =~ "0/#{Outbound.daily_cap_default()}"
  end

  defp enrollment_id_for(view, first_name) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find("[data-enrollment-id]")
    |> Enum.find(&(Floki.text(&1) =~ first_name))
    |> case do
      nil -> nil
      node -> node |> Floki.attribute("data-enrollment-id") |> List.first()
    end
  end
end
