defmodule DripdropDemo.Scenarios.Onboarding do
  @moduledoc """
  Demo context for the onboarding scenario. Owns the queries and enrollment
  workflow used by `DripdropDemoWeb.Scenarios.OnboardingLive`.
  """

  import Ecto.Query

  alias DripDrop.{Sequence, Step, StepExecution}
  alias DripdropDemo.Repo

  @sequence_key "onboarding"

  @type execution_row :: %{
          id: String.t(),
          step_key: String.t(),
          step_name: String.t(),
          channel: String.t(),
          state: String.t(),
          recipient: String.t() | nil,
          scheduled_for: DateTime.t() | nil,
          executed_at: DateTime.t() | nil,
          error_message: String.t() | nil
        }

  @doc "Returns true when the seeded onboarding sequence is present."
  @spec sequence_available?() :: boolean()
  def sequence_available? do
    Repo.exists?(from(sequence in Sequence, where: sequence.key == ^@sequence_key))
  end

  @doc """
  Enrolls the canonical demo onboarding subscriber. Returns the new enrollment
  on success or `{:error, reason}` if the seeded sequence is missing or
  `DripDrop.enroll/1` rejects the attrs.
  """
  @spec enroll() :: {:ok, DripDrop.Enrollment.t()} | {:error, term()}
  def enroll do
    case Repo.one(from(sequence in Sequence, where: sequence.key == ^@sequence_key, limit: 1)) do
      nil ->
        {:error, :seeded_onboarding_sequence_missing}

      sequence ->
        DripDrop.enroll(%{
          sequence_id: sequence.id,
          subscriber_type: "demo_user",
          subscriber_id: "onboarding-#{System.unique_integer([:positive])}",
          tenant_key: sequence.tenant_key,
          data: %{
            "first_name" => "Sam",
            "email" => "sam@example.com",
            "sms" => "+15555550101",
            "plan" => "standard",
            "setup_complete" => true
          }
        })
    end
  end

  @doc "Lists step executions for an enrollment, joined with their step rows."
  @spec list_executions(String.t()) :: [execution_row()]
  def list_executions(enrollment_id) do
    StepExecution
    |> where([execution], execution.enrollment_id == ^enrollment_id)
    |> join(:left, [execution], step in Step, on: step.id == execution.step_id)
    |> order_by([execution], asc: execution.inserted_at)
    |> select([execution, step], %{
      id: execution.id,
      step_key: step.key,
      step_name: step.name,
      channel: execution.channel,
      state: execution.state,
      recipient: execution.recipient,
      scheduled_for: execution.scheduled_for,
      executed_at: execution.executed_at,
      error_message: execution.error_message
    })
    |> Repo.all()
  end
end
