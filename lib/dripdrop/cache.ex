defmodule DripDrop.Cache do
  @moduledoc """
  Local Nebulex cache used for short-lived dispatch and provider state.
  """

  use Nebulex.Cache,
    otp_app: :dripdrop,
    adapter: Nebulex.Adapters.Local
end
