defmodule DripdropDemo.Repo do
  @moduledoc """
  Ecto repository used by the DripDrop demo host application.
  """

  use Ecto.Repo,
    otp_app: :dripdrop_demo,
    adapter: Ecto.Adapters.Postgres
end
