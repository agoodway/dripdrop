defmodule DripdropDemoWeb.Scenarios.OnboardingLiveTest do
  use DripdropDemoWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders in-app nudges delivered through the demo PubSub topic", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/scenarios/onboarding")

    assert html =~ "Sequence messages"

    Phoenix.PubSub.broadcast(
      DripdropDemo.PubSub,
      "demo:in_app",
      {"onboarding.nudge", %{"title" => "Finish setup", "message" => "Sam, complete setup."}}
    )

    assert render(view) =~ "Finish setup"
    assert render(view) =~ "Sam, complete setup."
  end
end
