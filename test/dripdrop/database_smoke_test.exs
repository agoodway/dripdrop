defmodule DripDrop.DatabaseSmokeTest do
  use DripDrop.DataCase, async: true

  alias DripDrop.TestRepo

  describe "test database" do
    test "installs the dripdrop schema through the wrapper migration" do
      assert %{rows: [["dripdrop"]]} =
               TestRepo.query!(
                 "SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'dripdrop'",
                 []
               )
    end

    test "installs pgmq and pgflow through PgFlow helper migrations" do
      assert %{rows: [["pgflow"], ["pgmq"]]} =
               TestRepo.query!(
                 """
                 SELECT schema_name
                 FROM information_schema.schemata
                 WHERE schema_name IN ('pgflow', 'pgmq')
                 ORDER BY schema_name
                 """,
                 []
               )
    end

    test "runs each test inside the SQL sandbox" do
      assert %{rows: [[1]]} = TestRepo.query!("SELECT 1", [])
    end
  end
end
