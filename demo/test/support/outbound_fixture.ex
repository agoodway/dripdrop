defmodule DripdropDemo.Test.OutboundFixture do
  @moduledoc """
  Minimal seed for outbound campaigns scenario tests.

  Mirrors the outbound section of `priv/repo/seeds.exs` (lines 573-717) but
  omits the onboarding and lead-nurture sequences so tests don't pay for
  unrelated setup. Sender adapter caps must match
  `DripdropDemo.Scenarios.Outbound.daily_cap_default/0` and `min_gap_default/0`
  so the "Reset capacity" test asserts against the same value as runtime.

  If the canonical outbound seed in `seeds.exs` evolves (new sender count,
  changed step keys, new conditions), update this fixture in lockstep.
  """

  alias DripDrop.{AdapterPools, ChannelAdapter, SequenceAuthoring}
  alias DripdropDemo.Repo
  alias DripdropDemo.Scenarios.Outbound

  @tenant_key "demo"

  @doc """
  Seeds the minimal object graph needed for `OutboundLive` tests:

  3 sender adapters → outbound_pool → 3 pool members → outbound-campaigns
  sequence + version (mode :outbound) → 3 steps (intro, follow-up, final-bump)
  → step transitions → validate + activate.
  """
  @spec seed_outbound_minimal() :: :ok
  def seed_outbound_minimal do
    senders = create_senders()
    pool = create_pool()
    Enum.each(senders, &add_pool_member(pool, &1))

    sequence = create_sequence()
    version = create_version(sequence, pool)
    steps = create_steps(version)
    create_transitions(version, steps)

    {:ok, _} = SequenceAuthoring.validate_sequence_version(version.id)
    {:ok, _} = SequenceAuthoring.activate_sequence_version(version.id)

    :ok
  end

  defp create_senders do
    [
      {"Goodway Alex", "alex@goodway.dev"},
      {"Goodway Jamie", "jamie@goodway.dev"},
      {"Goodway Sam", "sam@goodway.dev"}
    ]
    |> Enum.map(fn {name, email} ->
      %ChannelAdapter{}
      |> ChannelAdapter.changeset(%{
        tenant_key: @tenant_key,
        active: true,
        health_state: :active,
        name: name,
        channel: "email",
        provider: "local",
        is_default: false,
        credentials: %{"from" => "#{name} <#{email}>"},
        daily_cap: Outbound.daily_cap_default(),
        min_gap_seconds: Outbound.min_gap_default()
      })
      |> Repo.insert!()
    end)
  end

  defp create_pool do
    {:ok, pool} =
      AdapterPools.create_adapter_pool(%{
        tenant_key: @tenant_key,
        name: "outbound_pool",
        on_pin_unavailable: :reassign
      })

    pool
  end

  defp add_pool_member(pool, adapter) do
    {:ok, _member} =
      AdapterPools.add_pool_member(pool, %{
        tenant_key: @tenant_key,
        adapter_id: adapter.id,
        class: "mailbox",
        weight: 1,
        active: true
      })
  end

  defp create_sequence do
    {:ok, sequence} =
      SequenceAuthoring.create_sequence(%{
        tenant_key: @tenant_key,
        name: "Goodway Elixir consulting outbound",
        key: "outbound-campaigns",
        description: "Outbound campaign for Goodway Elixir software development consulting.",
        active: true,
        metadata: %{"demo" => true}
      })

    sequence
  end

  defp create_version(sequence, pool) do
    {:ok, version} =
      SequenceAuthoring.create_sequence_version(sequence.id, %{
        version: 1,
        name: "Goodway consulting campaign",
        mode: :outbound,
        config: %{"pool_id" => pool.id}
      })

    version
  end

  defp create_steps(version) do
    [
      step_attrs(:intro),
      step_attrs(:follow_up),
      step_attrs(:final_bump)
    ]
    |> Enum.map(fn attrs ->
      {:ok, step} = SequenceAuthoring.create_step(version.id, attrs)
      step
    end)
  end

  defp create_transitions(version, [intro, follow_up, final_bump]) do
    Enum.each(
      [
        {intro, follow_up},
        {follow_up, final_bump},
        {final_bump, nil}
      ],
      fn {from_step, to_step} ->
        {:ok, _transition} =
          SequenceAuthoring.create_step_transition(version.id, %{
            from_step_id: from_step.id,
            to_step_id: to_step && to_step.id,
            condition_mode: "always",
            priority: 1
          })
      end
    )
  end

  defp step_attrs(:intro) do
    %{
      name: "Initial consulting email",
      key: "consulting-intro",
      position: 1,
      channel: "email",
      timing: %{type: "immediate"},
      template_type: "inline",
      template_content: %{
        "subject" => "Phoenix and LiveView help for {{ company }}",
        "text" => "Hi {{ first_name }}, demo body.",
        "html" => "<p>Hi {{ first_name }}, demo body.</p>"
      },
      config: %{"quiet_hours" => false}
    }
  end

  defp step_attrs(:follow_up) do
    %{
      name: "Threaded follow-up",
      key: "consulting-follow-up",
      position: 2,
      channel: "email",
      timing: %{type: "delay", delay_amount: 10, delay_unit: "seconds"},
      template_type: "inline",
      template_content: %{
        "subject" => "Re: Phoenix and LiveView help for {{ company }}",
        "text" => "Follow-up demo body.",
        "html" => "<p>Follow-up demo body.</p>"
      },
      config: %{"quiet_hours" => false, "reply_behavior" => "pause_enrollment"}
    }
  end

  defp step_attrs(:final_bump) do
    %{
      name: "Final bump",
      key: "consulting-final-bump",
      position: 3,
      channel: "email",
      timing: %{type: "delay", delay_amount: 12, delay_unit: "seconds"},
      template_type: "inline",
      template_content: %{
        "subject" => "Re: Phoenix and LiveView help for {{ company }}",
        "text" => "Final bump demo body.",
        "html" => "<p>Final bump demo body.</p>"
      },
      config: %{"quiet_hours" => false, "reply_behavior" => "pause_enrollment"}
    }
  end
end
