defmodule DripdropDemoWeb.Router do
  @moduledoc """
  Routes browser pages, DripDrop webhooks, unsubscribe links, and dev tools.
  """

  use DripdropDemoWeb, :router
  import DripDrop.Web.Router

  alias DripDrop.Web.UnsubscribePlug

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DripdropDemoWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; " <>
          "script-src 'self' 'unsafe-inline'; " <>
          "style-src 'self' 'unsafe-inline'; " <>
          "img-src 'self' data:; " <>
          "connect-src 'self'"
    }
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :dripdrop_ingest do
    plug :accepts, ["json", "html", "form-urlencoded"]

    plug :put_secure_browser_headers, %{
      "content-security-policy" => "default-src 'none'; frame-ancestors 'none'"
    }
  end

  scope "/", DripdropDemoWeb do
    pipe_through :browser

    get "/", PageController, :home
    live "/scenarios/onboarding", Scenarios.OnboardingLive
    live "/scenarios/lead-nurture", Scenarios.LeadNurtureLive
    live "/scenarios/outbound", Scenarios.OutboundLive
  end

  scope "/" do
    pipe_through :dripdrop_ingest

    dripdrop_webhooks("/webhooks/dripdrop")
    forward "/u", UnsubscribePlug
  end

  # Other scopes may use custom stacks.
  # scope "/api", DripdropDemoWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:dripdrop_demo, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/" do
      pipe_through :browser

      live_dashboard "/phx-dashboard", metrics: DripdropDemoWeb.Telemetry
    end
  end
end
