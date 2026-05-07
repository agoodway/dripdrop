defmodule DripDrop.Migration do
  @moduledoc """
  Versioned DripDrop schema migrations for host applications.
  """

  use EctoEvolver,
    otp_app: :dripdrop,
    default_prefix: "dripdrop",
    tracking_object: {:view, "dripdrop_version"},
    versions: [DripDrop.Migrations.V01]
end
