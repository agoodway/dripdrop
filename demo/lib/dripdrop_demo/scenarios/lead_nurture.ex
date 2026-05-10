defmodule DripdropDemo.Scenarios.LeadNurture do
  @moduledoc """
  Demo context for the lead-nurture scenario. Owns the queries, fixture
  configuration (mock-hook scoring), and enrollment workflow used by
  `DripdropDemoWeb.Scenarios.LeadNurtureLive`.

  `enroll/1` performs external side effects against `DripdropDemo.MockHooks`
  to set the lead-score response for the chosen fixture before enrolling.
  """

  import Ecto.Query

  alias DripDrop.{Sequence, Step, StepExecution}
  alias DripdropDemo.{MockHooks, Repo}

  @sequence_key "lead-nurture"

  @type fixture :: :high_fit | :nurture | :invalid_email

  @type execution_row :: %{
          id: String.t(),
          step_key: String.t(),
          step_name: String.t(),
          channel: String.t(),
          state: String.t(),
          recipient: String.t() | nil,
          executed_at: DateTime.t() | nil,
          payload: map() | nil
        }

  @doc "Returns true when the seeded lead-nurture sequence is present."
  @spec sequence_available?() :: boolean()
  def sequence_available? do
    Repo.exists?(from(sequence in Sequence, where: sequence.key == ^@sequence_key))
  end

  @doc """
  Configures the mock lead-score endpoint for the chosen fixture and enrolls
  a fixture lead. Performs side effects against `DripdropDemo.MockHooks`
  before calling `DripDrop.enroll/1`.
  """
  @spec enroll(fixture()) :: {:ok, DripDrop.Enrollment.t()} | {:error, term()}
  def enroll(fixture) when fixture in [:high_fit, :nurture, :invalid_email] do
    configure_fixture(fixture)

    case Repo.one(from(sequence in Sequence, where: sequence.key == ^@sequence_key, limit: 1)) do
      nil -> {:error, :seeded_lead_nurture_sequence_missing}
      sequence -> DripDrop.enroll(enrollment_attrs(sequence, fixture))
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
      executed_at: execution.executed_at,
      payload: execution.payload
    })
    |> Repo.all()
  end

  defp configure_fixture(:high_fit), do: MockHooks.set_score("lead-high", 85)
  defp configure_fixture(:nurture), do: MockHooks.set_score("lead-low", 40)
  defp configure_fixture(:invalid_email), do: MockHooks.set_score("lead-invalid", 85)

  defp enrollment_attrs(sequence, fixture) do
    %{
      sequence_id: sequence.id,
      subscriber_type: "lead",
      subscriber_id: "#{fixture}-#{System.unique_integer([:positive])}",
      tenant_key: sequence.tenant_key,
      data: lead_data(fixture)
    }
  end

  defp lead_data(:high_fit) do
    Map.merge(base_lead_data(), %{
      "lead_id" => "lead-high",
      "company_size" => 85,
      "budget" => "50k_plus",
      "email_verification" => "valid"
    })
  end

  defp lead_data(:nurture) do
    Map.merge(base_lead_data(), %{
      "lead_id" => "lead-low",
      "company_size" => 24,
      "budget" => "exploring",
      "email_verification" => "valid"
    })
  end

  defp lead_data(:invalid_email) do
    Map.merge(base_lead_data(), %{
      "lead_id" => "lead-invalid",
      "email" => "sam.invalid",
      "company_size" => 85,
      "budget" => "50k_plus",
      "email_verification" => "invalid"
    })
  end

  defp base_lead_data do
    %{
      "first_name" => "Sam",
      "email" => "sam@example.com",
      "sms" => "+15555550101",
      "company" => "Acme Analytics",
      "role" => "VP Engineering",
      "interest" => "Elixir / Phoenix consulting",
      "source" => "pricing_page"
    }
  end
end
