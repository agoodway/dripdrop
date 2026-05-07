defmodule DripDrop.Web.Router do
  @moduledoc """
  Router macro for mounting DripDrop provider webhooks.

  The macro expands to a Plug/Phoenix `forward/2` call, so it can be used inside
  a Phoenix router without making DripDrop depend on Phoenix.
  """

  defmacro dripdrop_webhooks(path) do
    quote bind_quoted: [path: path] do
      forward(path, to: DripDrop.Web.WebhookPlug)
    end
  end
end
