defmodule DripDrop.Web.Router do
  @moduledoc """
  Router macro for mounting DripDrop provider webhooks.

  The macro expands to the `forward` form expected by the caller router, so it
  can be used inside Plug.Router and Phoenix.Router without making DripDrop
  depend on Phoenix.
  """

  defmacro dripdrop_webhooks(path) do
    if phoenix_router?(__CALLER__) do
      quote bind_quoted: [path: path] do
        forward(path, DripDrop.Web.WebhookPlug)
      end
    else
      quote bind_quoted: [path: path] do
        forward(path, to: DripDrop.Web.WebhookPlug)
      end
    end
  end

  defp phoenix_router?(env) do
    phoenix_router = Module.concat([Phoenix, Router])

    Enum.any?(env.macros, fn
      {^phoenix_router, macros} -> {:forward, 2} in macros or {:forward, 3} in macros
      _other -> false
    end)
  end
end
