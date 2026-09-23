defmodule DripDrop.TestRepo.Migrations.UpgradePgflow05 do
  use Ecto.Migration

  def up do
    PgFlow.Migration.up()
    PgFlow.HelpersMigration.up()
  end

  def down do
    PgFlow.HelpersMigration.down(version: 1)
    PgFlow.Migration.down(version: 1)
  end
end
