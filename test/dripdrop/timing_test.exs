defmodule DripDrop.TimingTest do
  use ExUnit.Case, async: true

  alias DripDrop.Timing

  describe "parse_human_friendly/1" do
    test "accepts second-level delay expressions" do
      assert {:ok, %{type: "delay", delay_amount: 5, delay_unit: "seconds"}} =
               Timing.parse_human_friendly("in 5 seconds")

      assert {:ok, %{type: "delay", delay_amount: 1, delay_unit: "seconds"}} =
               Timing.parse_human_friendly("in 1 second")
    end

    test "keeps existing larger delay units" do
      assert {:ok, %{type: "delay", delay_amount: 2, delay_unit: "minutes"}} =
               Timing.parse_human_friendly("in 2 minutes")

      assert {:ok, %{type: "delay", delay_amount: 1, delay_unit: "weeks"}} =
               Timing.parse_human_friendly("in 1 week")
    end
  end

  describe "changeset/2" do
    test "validates seconds as a supported delay unit" do
      changeset =
        Timing.changeset(%Timing{}, %{
          type: "delay",
          delay_amount: 15,
          delay_unit: "seconds"
        })

      assert changeset.valid?
    end
  end

  describe "calculate_next_run/2" do
    test "uses Elixir time-unit atoms for fixed delay units" do
      from = ~U[2026-05-08 12:00:00Z]

      assert {:ok, ~U[2026-05-08 12:00:05Z]} =
               Timing.calculate_next_run(delay(5, "seconds"), from)

      assert {:ok, ~U[2026-05-08 12:02:00Z]} =
               Timing.calculate_next_run(delay(2, "minutes"), from)

      assert {:ok, ~U[2026-05-22 12:00:00Z]} =
               Timing.calculate_next_run(delay(2, "weeks"), from)
    end
  end

  defp delay(amount, unit) do
    %Timing{type: "delay", delay_amount: amount, delay_unit: unit}
  end
end
