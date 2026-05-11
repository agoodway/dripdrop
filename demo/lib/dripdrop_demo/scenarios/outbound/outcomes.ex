defmodule DripdropDemo.Scenarios.Outbound.Outcomes do
  @moduledoc """
  Outcome map for the outbound campaigns demo prospects.
  """

  @type outcome ::
          :ghost
          | :reply_positive
          | :reply_ooo
          | :hard_bounce
          | :soft_bounce
          | :unsubscribe
          | :ramp_cap
          | :rest_pinned_sender

  @outcomes [
    {"Mia", :ghost},
    {"Jordan", :reply_positive},
    {"Priya", :reply_ooo},
    {"Eli", :hard_bounce},
    {"Nora", :soft_bounce},
    {"Theo", :unsubscribe},
    {"Avery", :ramp_cap},
    {"Quinn", :rest_pinned_sender}
  ]

  @outcomes_by_name Map.new(@outcomes)
  @valid_outcomes @outcomes |> Enum.map(&elem(&1, 1)) |> MapSet.new()

  @doc "Returns every first-name/outcome pair in prospect order."
  @spec all() :: [{String.t(), outcome()}]
  def all, do: @outcomes

  @doc "Returns the configured outcome for a prospect first name."
  @spec for_first_name(String.t() | nil) :: outcome()
  def for_first_name(first_name), do: Map.get(@outcomes_by_name, first_name, :ghost)

  @doc "Returns true when the atom is a configured demo outcome."
  @spec valid?(atom()) :: boolean()
  def valid?(outcome), do: MapSet.member?(@valid_outcomes, outcome)
end
