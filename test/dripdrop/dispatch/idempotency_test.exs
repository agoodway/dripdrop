defmodule DripDrop.Dispatch.IdempotencyTest do
  @moduledoc """
  Parity test (T1): the Elixir `Idempotency.key/4` digest must match the
  PostgreSQL `dripdrop.idempotency_key` function digest for the same inputs.
  A divergence here causes silent duplicate sends since the bulk-seed
  `INSERT ... SELECT` and any future SQL caller use the function directly,
  while every Elixir writer uses `key/4`.

  The "GUC-flipped" test covers the historical drift bug where session
  timezone affected `date_trunc` on a `timestamptz` and produced different
  digests across two Postgres sessions.
  """

  use DripDrop.DataCase, async: false

  alias DripDrop.Dispatch.Idempotency
  alias DripDrop.Fixtures
  alias DripDrop.TestRepo

  @schema Application.compile_env(:dripdrop, :schema, "dripdrop")

  setup do
    sequence = Fixtures.sequence_fixture()
    version = Fixtures.sequence_version_fixture(sequence)
    enrollment = Fixtures.enrollment_fixture(sequence, version)
    {:ok, enrollment: enrollment}
  end

  test "Elixir key/4 and SQL idempotency_key() produce the same digest", %{enrollment: enrollment} do
    sql = "SELECT #{Idempotency.sql_call(@schema, "$4::uuid")}"

    for _ <- 1..50 do
      step_id = Ecto.UUID.generate()
      scheduled_for = random_datetime()
      attempt = :rand.uniform(10) - 1

      elixir_key = Idempotency.key(enrollment.id, step_id, scheduled_for, attempt)

      {:ok, %{rows: [[sql_key]]}} =
        TestRepo.query(sql, [
          Ecto.UUID.dump!(step_id),
          scheduled_for,
          attempt,
          Ecto.UUID.dump!(enrollment.id)
        ])

      assert elixir_key == sql_key,
             "parity mismatch for step=#{step_id}, time=#{inspect(scheduled_for)}, attempt=#{attempt}"
    end
  end

  test "parity holds when the Postgres session TimeZone is not UTC", %{enrollment: enrollment} do
    sql = "SELECT #{Idempotency.sql_call(@schema, "$4::uuid")}"

    {:ok, _} =
      TestRepo.transaction(fn ->
        TestRepo.query!("SET LOCAL TimeZone TO 'America/New_York'", [])

        for _ <- 1..30 do
          step_id = Ecto.UUID.generate()
          scheduled_for = random_datetime()
          attempt = :rand.uniform(10) - 1

          elixir_key = Idempotency.key(enrollment.id, step_id, scheduled_for, attempt)

          {:ok, %{rows: [[sql_key]]}} =
            TestRepo.query(sql, [
              Ecto.UUID.dump!(step_id),
              scheduled_for,
              attempt,
              Ecto.UUID.dump!(enrollment.id)
            ])

          assert elixir_key == sql_key,
                 "non-UTC GUC drift: step=#{step_id}, time=#{inspect(scheduled_for)}, attempt=#{attempt}"
        end
      end)
  end

  defp random_datetime do
    offset = :rand.uniform(86_400 * 30) - 86_400 * 15
    DateTime.add(DateTime.utc_now(:second), offset, :second)
  end
end
