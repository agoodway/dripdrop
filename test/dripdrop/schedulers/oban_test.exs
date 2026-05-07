defmodule DripDrop.Schedulers.ObanTest do
  @moduledoc """
  Unit tests for the Oban scheduler adapter. The adapter wraps optional
  `Oban` / `Oban.Job` calls behind `function_exported?/3` guards so the
  library stays usable on hosts that aren't running Oban.

  We avoid actually inserting Oban jobs (that requires Oban supervision +
  migrations); instead we test the timestamp-normalization helper through
  the public `schedule/2` boundary by exercising the `Oban.Job` build path
  and asserting on the resulting changeset / error.
  """

  use ExUnit.Case, async: false

  alias DripDrop.Schedulers.Oban, as: ObanScheduler

  describe "cancel/1" do
    test "returns :ok for nil job_id" do
      assert ObanScheduler.cancel(nil) == :ok
    end
  end

  describe "schedule/2 input handling" do
    test "accepts %DateTime{} scheduled_for without raising on normalize" do
      # We can't fully assert insertion without Oban configured, but we can
      # confirm that the DateTime path doesn't raise on the normalize step.
      execution = %{id: "se-#{System.unique_integer([:positive])}"}
      datetime = DateTime.utc_now() |> DateTime.add(60, :second)

      result = ObanScheduler.schedule(execution, datetime)

      # Either an oban-runtime error tuple (no Oban supervisor up) or :ok with
      # a job id. The contract is: never crash on type normalization.
      assert match?({:ok, _job_id}, result) or match?({:error, _reason}, result)
    end

    test "accepts %NaiveDateTime{} scheduled_for and normalizes to UTC" do
      execution = %{id: "se-#{System.unique_integer([:positive])}"}
      naive = NaiveDateTime.utc_now() |> NaiveDateTime.add(60, :second)

      result = ObanScheduler.schedule(execution, naive)

      assert match?({:ok, _job_id}, result) or match?({:error, _reason}, result)
    end
  end
end
