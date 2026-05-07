defmodule DripDrop.ClockTest do
  use ExUnit.Case, async: false

  alias DripDrop.Clock

  setup do
    previous = Application.get_env(:dripdrop, :clock)
    on_exit(fn -> Application.put_env(:dripdrop, :clock, previous) end)
    :ok
  end

  describe "now/0" do
    test "returns a UTC DateTime truncated to the second" do
      now = Clock.now()
      assert %DateTime{time_zone: "Etc/UTC", microsecond: {0, 0}} = now
    end

    test "delegates to the configured clock module" do
      defmodule FrozenClock do
        @behaviour DripDrop.Clock
        @impl true
        def now, do: ~U[2026-05-07 12:00:00Z]
      end

      Application.put_env(:dripdrop, :clock, FrozenClock)
      assert Clock.now() == ~U[2026-05-07 12:00:00Z]
    end
  end

  describe "seconds_from_now/1" do
    test "shifts now by a positive number of seconds" do
      result = Clock.seconds_from_now(60)
      diff = DateTime.diff(result, Clock.now(), :second)
      assert diff in 59..61
    end

    test "shifts now by a negative number of seconds for past timestamps" do
      result = Clock.seconds_from_now(-300)
      diff = DateTime.diff(Clock.now(), result, :second)
      assert diff in 299..301
    end

    test "zero returns now" do
      assert DateTime.diff(Clock.seconds_from_now(0), Clock.now(), :second) in -1..1
    end
  end

  describe "shift/2" do
    test "advances a DateTime by N seconds" do
      base = ~U[2026-05-07 12:00:00Z]
      assert Clock.shift(base, 30) == ~U[2026-05-07 12:00:30Z]
    end

    test "negative shift moves backward" do
      base = ~U[2026-05-07 12:00:30Z]
      assert Clock.shift(base, -30) == ~U[2026-05-07 12:00:00Z]
    end

    test "preserves UTC timezone" do
      assert %DateTime{time_zone: "Etc/UTC"} = Clock.shift(~U[2026-05-07 12:00:00Z], 1)
    end
  end
end
