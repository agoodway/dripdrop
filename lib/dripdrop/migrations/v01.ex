defmodule DripDrop.Migrations.V01 do
  @moduledoc """
  Initial DripDrop schema migration registered with EctoEvolver.
  """

  use EctoEvolver.Version,
    otp_app: :dripdrop,
    version: "01",
    sql_path: "dripdrop/sql/versions"
end
