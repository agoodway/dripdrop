defmodule DripdropDemo.ScenarioSteps do
  @moduledoc """
  Shared helpers for reading seeded DripDrop scenario steps.
  """

  import Ecto.Query

  alias DripDrop.{Sequence, SequenceVersion, Step}
  alias DripdropDemo.Repo

  @doc """
  Lists the active DripDrop steps for a seeded demo sequence.
  """
  @spec active_steps(String.t()) :: [Step.t()]
  def active_steps(sequence_key) do
    Step
    |> join(:inner, [step], version in SequenceVersion,
      on: version.id == step.sequence_version_id
    )
    |> join(:inner, [_step, version], sequence in Sequence,
      on: sequence.id == version.sequence_id
    )
    |> where(
      [_step, version, sequence],
      sequence.key == ^sequence_key and version.state == "active"
    )
    |> order_by([step], asc: step.position)
    |> Repo.all()
  end

  @doc """
  Formats a DripDrop channel for the sequence step list.
  """
  @spec format_channel(term()) :: String.t()
  def format_channel(channel), do: channel |> to_string() |> String.capitalize()

  @doc """
  Formats DripDrop timing for the sequence step list.
  """
  @spec format_timing(map() | struct() | nil) :: String.t()
  def format_timing(%{type: "immediate"}), do: "Immediate"

  def format_timing(%{type: "delay", delay_amount: amount, delay_unit: unit}),
    do: "#{amount} #{unit_abbr(unit)}"

  def format_timing(_timing), do: "-"

  defp unit_abbr("seconds"), do: "sec"
  defp unit_abbr(unit), do: to_string(unit)
end
