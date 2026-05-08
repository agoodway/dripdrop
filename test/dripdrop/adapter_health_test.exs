defmodule DripDrop.AdapterHealthTest do
  use DripDrop.DataCase, async: false

  alias DripDrop.{AdapterHealth, Fixtures, TestRepo}

  describe "transition/3" do
    test "applies an allowed transition and emits telemetry" do
      attach_telemetry([:dripdrop, :health, :state_changed])
      adapter = Fixtures.channel_adapter_fixture(%{health_state: :active})
      resting_until = DateTime.add(DateTime.utc_now(:second), 3600, :second)

      assert {:ok, updated, [:state_changed_event]} =
               AdapterHealth.transition(adapter, :resting,
                 reason: :bounce_threshold,
                 resting_until: resting_until
               )

      assert updated.health_state == :resting
      assert updated.resting_until == resting_until
      assert updated.config["health"]["last_transition"]["from"] == "active"
      assert updated.config["health"]["last_transition"]["to"] == "resting"

      assert_receive {:telemetry, [:dripdrop, :health, :state_changed], %{count: 1},
                      %{from: "active", to: "resting", reason: :bounce_threshold}}
    end

    test "rejects undocumented automatic transitions" do
      adapter = Fixtures.channel_adapter_fixture(%{health_state: :active})

      assert {:error, :invalid_transition} = AdapterHealth.transition(adapter, :probing)
    end

    test "records probing_started_at when resting transitions to probing" do
      adapter = Fixtures.channel_adapter_fixture(%{health_state: :resting})

      assert {:ok, updated, _events} = AdapterHealth.transition(adapter, :probing)
      assert updated.health_state == :probing
      assert is_binary(updated.config["health"]["probing_started_at"])
    end
  end

  describe "set_adapter_health/2" do
    test "accepts external signals and emits telemetry" do
      attach_telemetry([:dripdrop, :health, :external_signal])
      adapter = Fixtures.channel_adapter_fixture()

      assert {:ok, updated} =
               DripDrop.set_adapter_health(adapter.id, %{
                 health_state: :ramping,
                 health_score: 0.82,
                 source: :postmaster_tools
               })

      assert updated.health_state == :ramping
      assert Decimal.equal?(updated.health_score, Decimal.from_float(0.82))

      assert_receive {:telemetry, [:dripdrop, :health, :external_signal], %{count: 1},
                      %{adapter_id: adapter_id, health_state: :ramping, source: :postmaster_tools}}

      assert adapter_id == adapter.id
    end

    test "rejects invalid external signal values" do
      adapter = Fixtures.channel_adapter_fixture()

      assert {:error, :invalid_health_state} =
               DripDrop.set_adapter_health(adapter.id, %{health_state: :dead})

      assert {:error, :invalid_health_score} =
               DripDrop.set_adapter_health(adapter.id, %{health_state: :active, health_score: 1.2})
    end
  end

  describe "effective_cap_today/1" do
    test "uses fixed probe budget for probing adapters" do
      Application.put_env(:dripdrop, :outbound_defaults, probe_daily_cap: 7)
      on_exit(fn -> Application.delete_env(:dripdrop, :outbound_defaults) end)

      adapter =
        Fixtures.channel_adapter_fixture(%{
          health_state: :probing,
          daily_cap: 50,
          ramp_floor: 5,
          ramp_increment: 2,
          ramp_started_at: DateTime.add(DateTime.utc_now(:second), -10, :day)
        })

      assert AdapterHealth.effective_cap_today(adapter) == 7
    end

    test "computes linear ramp values and caps at daily_cap" do
      ten_day =
        Fixtures.channel_adapter_fixture(%{
          health_state: :ramping,
          daily_cap: 50,
          ramp_floor: 5,
          ramp_increment: 2,
          ramp_started_at: DateTime.add(DateTime.utc_now(:second), -10, :day)
        })

      mature =
        ten_day
        |> Ecto.Changeset.change(
          ramp_started_at: DateTime.add(DateTime.utc_now(:second), -30, :day)
        )
        |> TestRepo.update!()

      assert AdapterHealth.effective_cap_today(ten_day) == 25
      assert AdapterHealth.effective_cap_today(mature) == 50
    end
  end

  describe "evaluate_probe/1" do
    test "promotes a successful probe to ramping after enough clean sends" do
      adapter = Fixtures.channel_adapter_fixture(%{health_state: :probing})

      for _index <- 1..5 do
        Fixtures.message_event_fixture(%{event_data: %{"adapter_id" => adapter.id}})
      end

      assert {:ok, updated} = AdapterHealth.evaluate_probe(adapter)
      assert updated.health_state == :ramping
    end

    test "rests a failed probe with exponential backoff capped at seven days" do
      adapter =
        Fixtures.channel_adapter_fixture(%{
          health_state: :probing,
          config: %{"probe_backoff_seconds" => 6 * 86_400}
        })

      for _index <- 1..5 do
        Fixtures.message_event_fixture(%{event_data: %{"adapter_id" => adapter.id}})
      end

      Fixtures.message_event_fixture(%{
        event_type: "bounced",
        event_data: %{"adapter_id" => adapter.id}
      })

      assert {:ok, updated} = AdapterHealth.evaluate_probe(adapter)
      assert updated.health_state == :resting
      assert updated.config["probe_backoff_seconds"] == 7 * 86_400
      assert %DateTime{} = updated.resting_until
    end

    test "ignores non-probing adapters" do
      adapter = Fixtures.channel_adapter_fixture(%{health_state: :active})

      assert :ok = AdapterHealth.evaluate_probe(adapter)
    end
  end

  describe "evaluate_probes/0" do
    test "promotes healthy probing adapters and rests breached ones in one pass" do
      healthy =
        Fixtures.channel_adapter_fixture(%{
          name: "healthy_probe",
          health_state: :probing
        })

      breached =
        Fixtures.channel_adapter_fixture(%{
          name: "breached_probe",
          health_state: :probing,
          config: %{"probe_backoff_seconds" => 86_400}
        })

      for _index <- 1..5 do
        Fixtures.message_event_fixture(%{event_data: %{"adapter_id" => healthy.id}})
        Fixtures.message_event_fixture(%{event_data: %{"adapter_id" => breached.id}})
      end

      Fixtures.message_event_fixture(%{
        event_type: "bounced",
        event_data: %{"adapter_id" => breached.id}
      })

      assert {:ok, evaluated} = AdapterHealth.evaluate_probes()
      assert evaluated >= 2

      assert TestRepo.get!(DripDrop.ChannelAdapter, healthy.id).health_state == :ramping
      assert TestRepo.get!(DripDrop.ChannelAdapter, breached.id).health_state == :resting
    end
  end

  describe "transition/3 ramping → active" do
    test "graduates a ramping adapter back to active and clears ramp anchors" do
      attach_telemetry([:dripdrop, :health, :state_changed])

      adapter =
        Fixtures.channel_adapter_fixture(%{
          health_state: :ramping,
          ramp_started_at: DateTime.add(DateTime.utc_now(:second), -30, :day),
          ramp_floor: 5,
          ramp_increment: 2,
          daily_cap: 50
        })

      assert {:ok, updated, _events} =
               AdapterHealth.transition(adapter, :active, reason: :ramp_complete)

      assert updated.health_state == :active
      assert updated.config["health"]["last_transition"]["from"] == "ramping"
      assert updated.config["health"]["last_transition"]["to"] == "active"

      assert_receive {:telemetry, [:dripdrop, :health, :state_changed], %{count: 1},
                      %{from: "ramping", to: "active", reason: :ramp_complete}}
    end
  end

  defp attach_telemetry(event) do
    test = self()
    handler_id = {__MODULE__, event, System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      event,
      fn event, measurements, metadata, _config ->
        send(test, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
