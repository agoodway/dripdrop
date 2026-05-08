defmodule DripDrop.AdapterPoolsTest do
  use DripDrop.DataCase, async: false

  alias DripDrop.{
    AdapterPool,
    AdapterPoolMember,
    AdapterSequenceBudget,
    ChannelAdapter,
    Fixtures,
    TestRepo
  }

  alias DripDrop.AdapterPools.WDRR

  describe "adapter pools" do
    test "creates and lists pools per tenant" do
      assert {:ok, pool} =
               DripDrop.create_adapter_pool(%{
                 tenant_key: "tenant-a",
                 name: "primary_outbound",
                 on_pin_unavailable: "pause"
               })

      assert %AdapterPool{on_pin_unavailable: :pause} = pool
      assert [listed] = DripDrop.list_adapter_pools(%{tenant_key: "tenant-a"})
      assert listed.id == pool.id
      assert DripDrop.list_adapter_pools(%{tenant_key: "tenant-b"}) == []
    end

    test "requires explicit tenant scope for list APIs" do
      assert_raise ArgumentError, ~r/list_adapter_pools requires an explicit :tenant_key/, fn ->
        DripDrop.list_adapter_pools(%{})
      end
    end

    test "updates a pool inside the caller tenant scope" do
      pool = Fixtures.adapter_pool_fixture(%{tenant_key: "tenant-a"})

      assert {:ok, updated} =
               DripDrop.update_adapter_pool(pool.id, %{
                 tenant_key: "tenant-a",
                 name: "updated",
                 on_pin_unavailable: :reassign
               })

      assert updated.name == "updated"
      assert updated.on_pin_unavailable == :reassign
    end
  end

  describe "pool members" do
    test "adds and lists weighted mailbox members" do
      pool = Fixtures.adapter_pool_fixture(%{tenant_key: "tenant-a"})
      adapter = Fixtures.channel_adapter_fixture(%{tenant_key: "tenant-a"})

      assert {:ok, member} =
               DripDrop.add_pool_member(pool.id, %{
                 tenant_key: "tenant-a",
                 adapter_id: adapter.id,
                 class: :mailbox,
                 weight: 3
               })

      assert %AdapterPoolMember{class: :mailbox, weight: 3} = member
      assert [listed] = DripDrop.list_pool_members(%{tenant_key: "tenant-a", pool_id: pool.id})
      assert listed.id == member.id
      assert listed.adapter.id == adapter.id
    end

    test "rejects ESP API adapters in mailbox-class slots" do
      pool = Fixtures.adapter_pool_fixture(%{tenant_key: "tenant-a"})

      adapter =
        Fixtures.channel_adapter_fixture(%{
          tenant_key: "tenant-a",
          provider: "mailgun",
          credentials: %{"api_key" => "secret", "domain" => "mg.example.com"}
        })

      assert {:error, changeset} =
               DripDrop.add_pool_member(pool.id, %{
                 tenant_key: "tenant-a",
                 adapter_id: adapter.id,
                 class: :mailbox
               })

      assert %{class: ["class_mismatch"]} = errors_on(changeset)
    end

    test "rejects cross-tenant adapters" do
      pool = Fixtures.adapter_pool_fixture(%{tenant_key: "tenant-a"})
      adapter = Fixtures.channel_adapter_fixture(%{tenant_key: "tenant-b"})

      assert {:error, changeset} =
               DripDrop.add_pool_member(pool.id, %{
                 tenant_key: "tenant-a",
                 adapter_id: adapter.id
               })

      assert %{adapter_id: ["tenant_mismatch"]} = errors_on(changeset)
    end

    test "removes a pool member without touching the adapter" do
      pool = Fixtures.adapter_pool_fixture(%{tenant_key: "tenant-a"})
      adapter = Fixtures.channel_adapter_fixture(%{tenant_key: "tenant-a"})
      member = Fixtures.adapter_pool_member_fixture(pool, adapter)

      assert {:ok, removed} =
               DripDrop.remove_pool_member(pool.id, %{
                 tenant_key: "tenant-a",
                 adapter_id: adapter.id
               })

      assert removed.id == member.id
      assert TestRepo.get(AdapterPoolMember, member.id) == nil
      assert TestRepo.get!(ChannelAdapter, adapter.id)
    end

    test "removing a pool member preserves existing enrollment pins" do
      pool = Fixtures.adapter_pool_fixture(%{tenant_key: "tenant-a"})
      adapter = Fixtures.channel_adapter_fixture(%{tenant_key: "tenant-a"})
      Fixtures.adapter_pool_member_fixture(pool, adapter)
      sequence = Fixtures.sequence_fixture(%{tenant_key: "tenant-a"})
      version = Fixtures.sequence_version_fixture(sequence, %{config: %{"pool_id" => pool.id}})

      enrollment =
        Fixtures.enrollment_fixture(sequence, version, %{
          adapter_id: adapter.id,
          effective_mode: :outbound
        })

      assert {:ok, _removed} =
               DripDrop.remove_pool_member(pool.id, %{
                 tenant_key: "tenant-a",
                 adapter_id: adapter.id
               })

      assert TestRepo.get!(DripDrop.Enrollment, enrollment.id).adapter_id == adapter.id
    end
  end

  describe "WDRR allocator" do
    test "distributes fresh picks by member weight" do
      WDRR.reset!()

      pool = Fixtures.adapter_pool_fixture(%{tenant_key: "tenant-a"})
      sequence = Fixtures.sequence_fixture(%{tenant_key: "tenant-a"})
      version = Fixtures.sequence_version_fixture(sequence)

      first =
        Fixtures.channel_adapter_fixture(%{
          tenant_key: "tenant-a",
          name: "First",
          health_state: :active
        })

      second =
        Fixtures.channel_adapter_fixture(%{
          tenant_key: "tenant-a",
          name: "Second",
          health_state: :active
        })

      Fixtures.adapter_pool_member_fixture(pool, first, %{weight: 3})
      Fixtures.adapter_pool_member_fixture(pool, second, %{weight: 1})

      picked_ids =
        for _index <- 1..4 do
          assert {:ok, member} = WDRR.pick_member(pool, version)
          member.adapter_id
        end

      assert Enum.count(picked_ids, &(&1 == first.id)) == 3
      assert Enum.count(picked_ids, &(&1 == second.id)) == 1
    end

    test "skips resting members and members without daily-cap headroom" do
      WDRR.reset!()

      pool = Fixtures.adapter_pool_fixture(%{tenant_key: "tenant-a"})
      sequence = Fixtures.sequence_fixture(%{tenant_key: "tenant-a"})
      version = Fixtures.sequence_version_fixture(sequence)

      resting =
        Fixtures.channel_adapter_fixture(%{
          tenant_key: "tenant-a",
          name: "Resting",
          health_state: :resting,
          resting_until: DateTime.add(DateTime.utc_now(:second), 3600, :second)
        })

      capped =
        Fixtures.channel_adapter_fixture(%{
          tenant_key: "tenant-a",
          name: "Capped",
          health_state: :active,
          daily_cap: 1
        })

      available =
        Fixtures.channel_adapter_fixture(%{
          tenant_key: "tenant-a",
          name: "Available",
          health_state: :active
        })

      Fixtures.adapter_pool_member_fixture(pool, resting)
      Fixtures.adapter_pool_member_fixture(pool, capped)
      Fixtures.adapter_pool_member_fixture(pool, available)
      Fixtures.message_event_fixture(%{event_data: %{"adapter_id" => capped.id}})

      assert {:ok, member} = WDRR.pick_member(pool, version)
      assert member.adapter_id == available.id
    end

    test "moves elapsed resting members into probing before selection" do
      WDRR.reset!()

      pool = Fixtures.adapter_pool_fixture(%{tenant_key: "tenant-a"})
      sequence = Fixtures.sequence_fixture(%{tenant_key: "tenant-a"})
      version = Fixtures.sequence_version_fixture(sequence)

      adapter =
        Fixtures.channel_adapter_fixture(%{
          tenant_key: "tenant-a",
          health_state: :resting,
          resting_until: DateTime.add(DateTime.utc_now(:second), -60, :second)
        })

      Fixtures.adapter_pool_member_fixture(pool, adapter)

      assert {:ok, member} = WDRR.pick_member(pool, version)
      assert member.adapter_id == adapter.id
      assert TestRepo.get!(ChannelAdapter, adapter.id).health_state == :probing
    end

    test "equal-weight members alternate evenly across many picks" do
      WDRR.reset!()

      pool = Fixtures.adapter_pool_fixture(%{tenant_key: "tenant-a"})
      sequence = Fixtures.sequence_fixture(%{tenant_key: "tenant-a"})
      version = Fixtures.sequence_version_fixture(sequence)

      first =
        Fixtures.channel_adapter_fixture(%{
          tenant_key: "tenant-a",
          name: "Even-A",
          health_state: :active
        })

      second =
        Fixtures.channel_adapter_fixture(%{
          tenant_key: "tenant-a",
          name: "Even-B",
          health_state: :active
        })

      Fixtures.adapter_pool_member_fixture(pool, first, %{weight: 1})
      Fixtures.adapter_pool_member_fixture(pool, second, %{weight: 1})

      picks =
        for _index <- 1..8 do
          assert {:ok, member} = WDRR.pick_member(pool, version)
          member.adapter_id
        end

      assert Enum.count(picks, &(&1 == first.id)) == 4
      assert Enum.count(picks, &(&1 == second.id)) == 4
    end

    test "reset! clears in-memory counters so weights re-distribute" do
      WDRR.reset!()

      pool = Fixtures.adapter_pool_fixture(%{tenant_key: "tenant-a"})
      sequence = Fixtures.sequence_fixture(%{tenant_key: "tenant-a"})
      version = Fixtures.sequence_version_fixture(sequence)

      a =
        Fixtures.channel_adapter_fixture(%{
          tenant_key: "tenant-a",
          name: "Reset-A",
          health_state: :active
        })

      b =
        Fixtures.channel_adapter_fixture(%{
          tenant_key: "tenant-a",
          name: "Reset-B",
          health_state: :active
        })

      Fixtures.adapter_pool_member_fixture(pool, a, %{weight: 3})
      Fixtures.adapter_pool_member_fixture(pool, b, %{weight: 1})

      first_window =
        for _index <- 1..4 do
          assert {:ok, member} = WDRR.pick_member(pool, version)
          member.adapter_id
        end

      WDRR.reset!()

      second_window =
        for _index <- 1..4 do
          assert {:ok, member} = WDRR.pick_member(pool, version)
          member.adapter_id
        end

      assert Enum.count(first_window, &(&1 == a.id)) == 3
      assert Enum.count(second_window, &(&1 == a.id)) == 3
    end
  end

  describe "pool deletion" do
    test "blocks deletion when active enrollments reference the pool unless forced" do
      pool = Fixtures.adapter_pool_fixture(%{tenant_key: "tenant-a"})
      sequence = Fixtures.sequence_fixture(%{tenant_key: "tenant-a"})
      version = Fixtures.sequence_version_fixture(sequence, %{config: %{"pool_id" => pool.id}})
      _enrollment = Fixtures.enrollment_fixture(sequence, version)

      assert {:error, %{reason: :pool_in_use, active_enrollment_count: 1}} =
               DripDrop.delete_adapter_pool(pool.id, %{tenant_key: "tenant-a"})

      assert {:ok, deleted} =
               DripDrop.delete_adapter_pool(pool.id, %{tenant_key: "tenant-a", force: true})

      assert deleted.id == pool.id
      assert TestRepo.get(AdapterPool, pool.id) == nil
    end
  end

  describe "adapter sequence budgets" do
    test "creates and updates an adapter sequence budget" do
      sequence = Fixtures.sequence_fixture(%{tenant_key: "tenant-a"})
      version = Fixtures.sequence_version_fixture(sequence)
      adapter = Fixtures.channel_adapter_fixture(%{tenant_key: "tenant-a"})

      assert {:ok, budget} =
               DripDrop.set_adapter_sequence_budget(adapter.id, version.id, %{
                 max_share_pct: 50,
                 daily_volume_target: 15
               })

      assert %AdapterSequenceBudget{max_share_pct: 50, daily_volume_target: 15} = budget

      assert {:ok, updated} =
               DripDrop.set_adapter_sequence_budget(adapter.id, version.id, %{max_share_pct: 40})

      assert updated.id == budget.id
      assert updated.max_share_pct == 40
    end
  end
end
