defmodule DripDrop.TestRepo do
  @moduledoc """
  Ecto repo used by DripDrop's database-backed tests.
  """

  use Ecto.Repo,
    otp_app: :dripdrop,
    adapter: Ecto.Adapters.Postgres
end
