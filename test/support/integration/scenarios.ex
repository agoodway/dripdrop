defmodule DripDrop.TestSupport.Integration.Scenarios do
  @moduledoc """
  Small builders for integration-test data.
  """

  alias DripDrop.Fixtures

  @doc """
  Builds a two-step email sequence using a Mailgun adapter.

  By default this does not enroll a subscriber; full-stack tests should call
  `DripDrop.enroll/1` so the real scheduler path is exercised. Pass
  `enroll?: true` when a prebuilt fixture enrollment is useful.
  """
  @spec email_full_scenario(keyword()) :: map()
  def email_full_scenario(opts \\ []) do
    tenant_key = Keyword.get(opts, :tenant_key, "tenant-a")
    recipient = Keyword.get(opts, :recipient, "sam@example.com")
    domain = Keyword.get(opts, :domain, "mg.example.com")

    adapter =
      Fixtures.channel_adapter_fixture(%{
        tenant_key: tenant_key,
        name: "Mailgun integration",
        channel: "email",
        provider: "mailgun",
        credentials: %{
          "api_key" => "key-test",
          "domain" => domain,
          "webhook_signing_key" => "signing-key"
        },
        config: %{"req_options" => Keyword.get(opts, :req_options, [])},
        is_default: true
      })

    sequence =
      Fixtures.sequence_fixture(%{tenant_key: tenant_key, key: unique_key("integration")})

    version = Fixtures.sequence_version_fixture(sequence, %{state: "draft"})

    step =
      Fixtures.step_fixture(version, %{
        key: "welcome",
        position: 1,
        channel_adapter_id: adapter.id,
        template_content: %{
          "from" => "team@#{domain}",
          "subject" => "Welcome {{ first_name }}",
          "text" => "Hello {{ first_name }}",
          "html" => "<p>Hello {{ first_name }}</p>"
        }
      })

    next_step =
      Fixtures.step_fixture(version, %{
        key: "follow-up",
        position: 2,
        channel_adapter_id: adapter.id,
        template_content: %{
          "from" => "team@#{domain}",
          "subject" => "Next step",
          "text" => "Next step",
          "html" => "<p>Next step</p>"
        }
      })

    {:ok, version} = DripDrop.activate_sequence_version(version.id)

    enrollment =
      if Keyword.get(opts, :enroll?, false) do
        Fixtures.enrollment_fixture(sequence, version, %{
          tenant_key: tenant_key,
          subscriber_id: unique_key("subscriber"),
          data: %{"email" => recipient, "first_name" => "Sam"}
        })
      end

    %{
      sequence: sequence,
      version: version,
      step: step,
      next_step: next_step,
      enrollment: enrollment,
      adapter: adapter,
      recipient: recipient,
      enroll_attrs: %{
        sequence_id: sequence.id,
        subscriber_type: "user",
        subscriber_id: unique_key("subscriber"),
        tenant_key: tenant_key,
        data: %{"email" => recipient, "first_name" => "Sam"}
      }
    }
  end

  @doc """
  Builds an email scenario whose first step renders an HTTP-hook result.
  """
  @spec email_http_hook_scenario(keyword()) :: map()
  def email_http_hook_scenario(opts \\ []) do
    scenario = email_full_scenario(opts)

    hook =
      Fixtures.http_hook_fixture(scenario.sequence.id, %{
        tenant_key: scenario.sequence.tenant_key,
        key: "eligibility",
        name: "Eligibility",
        url: "http:///eligibility/{{ subscriber_id }}",
        body_template: ~s({"email": "{{ email }}"}),
        response_type: "json",
        response_path: nil,
        retry_count: 0
      })

    {:ok, _condition} =
      DripDrop.create_condition(scenario.step.id, %{
        condition_type: "hook",
        http_hook_id: hook.id
      })

    {:ok, step} =
      DripDrop.TestRepo.get!(DripDrop.Step, scenario.step.id)
      |> Ecto.Changeset.change(%{
        template_content: %{
          "from" => "team@mg.example.com",
          "subject" => "Welcome {{ first_name }}",
          "text" => "Eligibility: {{ eligibility.status }}",
          "html" => "<p>Eligibility: {{ eligibility.status }}</p>"
        }
      })
      |> DripDrop.TestRepo.update()

    scenario
    |> Map.put(:step, step)
    |> Map.put(:http_hook, hook)
  end

  defp unique_key(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
