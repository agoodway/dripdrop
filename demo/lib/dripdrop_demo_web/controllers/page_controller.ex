defmodule DripdropDemoWeb.PageController do
  @moduledoc """
  Serves the demo home page.
  """

  use DripdropDemoWeb, :controller

  alias DripdropDemo.ScenarioCatalog

  @doc """
  Renders the demo overview page.
  """
  @spec home(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def home(conn, _params) do
    render(conn, :home, scenarios: ScenarioCatalog.list())
  end
end
