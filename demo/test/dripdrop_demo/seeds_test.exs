defmodule DripdropDemo.SeedsTest do
  @moduledoc """
  Idempotency check for `priv/repo/seeds.exs`.

  The demo seed wipes the demo tenant via `reset_tenant.(tenant_key)` at the
  top, then re-creates every adapter, sequence, hook, pool, and pool member.
  Running it twice should produce identical row counts (no duplicates, no
  unique-constraint violations).
  """

  use DripdropDemo.DataCase

  import Ecto.Query

  alias DripDrop.{
    AdapterPool,
    AdapterPoolMember,
    ChannelAdapter,
    Condition,
    HttpHook,
    Sequence,
    SequenceVersion,
    Step,
    StepTransition
  }

  @tenant_key "demo"

  test "running seeds twice produces identical row counts (no duplicates)" do
    Code.eval_file("priv/repo/seeds.exs")
    snapshot_one = snapshot()

    Code.eval_file("priv/repo/seeds.exs")
    snapshot_two = snapshot()

    assert snapshot_one == snapshot_two
  end

  test "outbound pool has exactly 3 members after re-seed" do
    Code.eval_file("priv/repo/seeds.exs")
    Code.eval_file("priv/repo/seeds.exs")

    pool = Repo.get_by!(AdapterPool, tenant_key: @tenant_key, name: "outbound_pool")

    member_count =
      AdapterPoolMember
      |> where([m], m.pool_id == ^pool.id)
      |> Repo.aggregate(:count)

    assert member_count == 3
  end

  test "every demo sequence exists exactly once after re-seed" do
    Code.eval_file("priv/repo/seeds.exs")
    Code.eval_file("priv/repo/seeds.exs")

    for key <- ~w(onboarding lead-nurture outbound-campaigns) do
      count =
        Sequence
        |> where([s], s.tenant_key == ^@tenant_key and s.key == ^key)
        |> Repo.aggregate(:count)

      assert count == 1, "expected exactly one sequence with key #{inspect(key)}, got #{count}"
    end
  end

  defp snapshot do
    %{
      sequences: count(Sequence),
      versions: count(SequenceVersion),
      steps: count(Step),
      transitions: count(StepTransition),
      conditions: count(Condition),
      hooks: count(HttpHook),
      adapters: count(ChannelAdapter),
      pools: count(AdapterPool),
      pool_members: count(AdapterPoolMember)
    }
  end

  defp count(schema) do
    schema
    |> where([row], row.tenant_key == ^@tenant_key)
    |> Repo.aggregate(:count)
  end
end
