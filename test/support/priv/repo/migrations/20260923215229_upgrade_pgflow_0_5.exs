defmodule DripDrop.TestRepo.Migrations.UpgradePgflow05 do
  @moduledoc """
  Upgrades PgFlow to the pgflow 0.5 schema: core V02 and helpers V06.

  Pinned so replaying history on an empty database installs exactly what
  this migration originally installed; the V03/V07 upgrade runs later.
  """
  use Ecto.Migration

  def up do
    PgFlow.Migration.up(version: 2)
    PgFlow.HelpersMigration.up(version: 6)
  end

  def down do
    PgFlow.HelpersMigration.down(version: 1)
    PgFlow.Migration.down(version: 1)
  end
end
