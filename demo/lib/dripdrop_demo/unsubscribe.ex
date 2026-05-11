defmodule DripdropDemo.Unsubscribe do
  @moduledoc """
  Builds public unsubscribe URLs for outbound messages.

  Referenced from `config/config.exs` as `{DripdropDemo.Unsubscribe, :build_url}`
  so the compiled config stays release-safe (no anonymous functions).
  """

  alias DripdropDemoWeb.Endpoint

  @spec build_url(map()) :: binary()
  def build_url(%{token: token}) do
    Endpoint.url() <> "/u/#{token}"
  end
end
