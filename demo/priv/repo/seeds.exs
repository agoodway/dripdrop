alias DripdropDemo.Repo

alias DripDrop.{
  AdapterPools,
  ChannelAdapter,
  SequenceAuthoring
}

import Ecto.Query

tenant_key = "demo"
Code.ensure_loaded!(DripdropDemo.LeadNurtureHooks)

reset_tenant = fn tenant ->
  statements = [
    "DELETE FROM dripdrop.adapter_sequence_budgets WHERE tenant_key = $1",
    """
    DELETE FROM dripdrop.adapter_pool_members member
    USING dripdrop.adapter_pools pool
    WHERE member.pool_id = pool.id AND pool.tenant_key = $1
    """,
    "DELETE FROM dripdrop.adapter_pools WHERE tenant_key = $1",
    "DELETE FROM dripdrop.message_events WHERE tenant_key = $1",
    "DELETE FROM dripdrop.short_links WHERE tenant_key = $1",
    "DELETE FROM dripdrop.events WHERE tenant_key = $1",
    "DELETE FROM dripdrop.step_executions WHERE tenant_key = $1",
    "DELETE FROM dripdrop.suppressions WHERE tenant_key = $1",
    "DELETE FROM dripdrop.enrollments WHERE tenant_key = $1",
    "DELETE FROM dripdrop.conditions WHERE tenant_key = $1",
    "DELETE FROM dripdrop.step_transitions WHERE tenant_key = $1",
    "DELETE FROM dripdrop.steps WHERE tenant_key = $1",
    "DELETE FROM dripdrop.http_hooks WHERE tenant_key = $1",
    "DELETE FROM dripdrop.sequence_versions WHERE tenant_key = $1",
    "DELETE FROM dripdrop.sequences WHERE tenant_key = $1",
    "DELETE FROM dripdrop.channel_adapters WHERE tenant_key = $1"
  ]

  Enum.each(statements, &Repo.query!(&1, [tenant]))
end

create_adapter = fn attrs ->
  attrs =
    Map.merge(
      %{
        tenant_key: tenant_key,
        active: true,
        health_state: :active
      },
      attrs
    )

  %ChannelAdapter{}
  |> ChannelAdapter.changeset(attrs)
  |> Repo.insert!()
end

unwrap = fn
  {:ok, value} -> value
  {:error, reason} -> raise "seed failed: #{inspect(reason)}"
end

reset_tenant.(tenant_key)

email_adapter =
  create_adapter.(%{
    name: "Local email",
    channel: "email",
    provider: "local",
    is_default: true,
    credentials: %{"from" => "DripDrop Demo <demo@dripdrop.dev>"}
  })

sms_adapter =
  create_adapter.(%{
    name: "Local SMS",
    channel: "sms",
    provider: "local",
    is_default: true,
    credentials: %{"from" => "+15550001000"}
  })

pubsub_adapter =
  create_adapter.(%{
    name: "Phoenix PubSub",
    channel: "pubsub",
    provider: "phoenix_pubsub",
    is_default: true,
    credentials: %{
      "pubsub" => "DripdropDemo.PubSub",
      "topic" => "demo:in_app"
    }
  })

telegram_adapter =
  create_adapter.(%{
    name: "Local Telegram",
    channel: "telegram",
    provider: "local",
    is_default: true,
    credentials: %{"chat_id" => "@dripdrop_demo"}
  })

slack_adapter =
  create_adapter.(%{
    name: "Mock Slack",
    channel: "slack",
    provider: "webhook",
    is_default: true,
    credentials: %{"url" => DripdropDemo.MockHooks.url("/slack-alert")}
  })

webhook_adapter =
  create_adapter.(%{
    name: "Mock webhook",
    channel: "webhook",
    provider: "default",
    is_default: true,
    credentials: %{
      "url" => DripdropDemo.MockHooks.url("/crm-update"),
      "secret" => "whsec_#{Base.encode64("demo-webhook-secret")}"
    }
  })

sequence =
  %{
    tenant_key: tenant_key,
    name: "Onboarding demo",
    key: "onboarding",
    description:
      "Short lifecycle sequence for exercising email, PubSub, HTTP hooks, SMS, and Telegram.",
    active: true,
    metadata: %{"demo" => true}
  }
  |> SequenceAuthoring.create_sequence()
  |> unwrap.()

setup_status_hook =
  sequence.id
  |> DripDrop.create_http_hook(%{
    tenant_key: tenant_key,
    name: "Setup status check",
    key: "setup_status",
    description: "Checks whether the app has marked onboarding setup complete.",
    method: "GET",
    url:
      DripdropDemo.MockHooks.url(
        "/onboarding/setup-status?subscriber_id={{ subscriber_id }}&plan={{ plan }}&setup_complete={{ setup_complete }}"
      ),
    response_type: "boolean",
    response_path: "sms_followup_eligible",
    timeout_ms: 2_000,
    retry_count: 0
  })
  |> unwrap.()

version =
  sequence.id
  |> SequenceAuthoring.create_sequence_version(%{
    version: 1,
    name: "Local demo path",
    mode: :lifecycle,
    config: %{"demo_time_scale" => Application.fetch_env!(:dripdrop_demo, :demo_time_scale)}
  })
  |> unwrap.()

welcome_email =
  version.id
  |> SequenceAuthoring.create_step(%{
    name: "Welcome email",
    key: "welcome-email",
    position: 1,
    channel: "email",
    channel_adapter_id: email_adapter.id,
    timing: %{type: "immediate"},
    template_type: "inline",
    template_content: %{
      "subject" => "Welcome to DripDrop, {{ first_name }}",
      "text" => "Hi {{ first_name }}, your onboarding sequence has started.",
      "html" => "<p>Hi {{ first_name }}, your onboarding sequence has started.</p>"
    },
    config: %{"unsubscribe_headers" => true}
  })
  |> unwrap.()

in_app_nudge =
  version.id
  |> SequenceAuthoring.create_step(%{
    name: "In-app nudge",
    key: "in-app-nudge",
    position: 3,
    channel: "pubsub",
    channel_adapter_id: pubsub_adapter.id,
    timing: %{type: "delay", delay_amount: 10, delay_unit: "seconds"},
    template_type: "inline",
    template_content: %{
      "topic" => "demo:in_app",
      "event" => "onboarding.nudge",
      "payload" => %{
        "title" => "Finish setup",
        "message" => "{{ first_name }}, complete setup to unlock the next step."
      }
    },
    config: %{}
  })
  |> unwrap.()

setup_sms =
  version.id
  |> SequenceAuthoring.create_step(%{
    name: "Setup SMS",
    key: "setup-sms",
    position: 4,
    channel: "sms",
    channel_adapter_id: sms_adapter.id,
    timing: %{type: "delay", delay_amount: 12, delay_unit: "seconds"},
    template_type: "inline",
    template_content: %{
      "body" => "{{ first_name }}, your onboarding setup is complete!"
    },
    config: %{"recipient_key" => "sms"}
  })
  |> unwrap.()

telegram_message =
  version.id
  |> SequenceAuthoring.create_step(%{
    name: "Telegram team alert",
    key: "telegram-message",
    position: 2,
    channel: "telegram",
    channel_adapter_id: telegram_adapter.id,
    timing: %{type: "delay", delay_amount: 2, delay_unit: "seconds"},
    template_type: "inline",
    template_content: %{
      "chat_id" => "@dripdrop_demo",
      "text" => "New signup: {{ first_name }} joined the onboarding flow."
    },
    config: %{}
  })
  |> unwrap.()

version.id
|> SequenceAuthoring.create_step_transition(%{
  from_step_id: welcome_email.id,
  to_step_id: telegram_message.id,
  condition_mode: "always",
  priority: 1
})
|> unwrap.()

version.id
|> SequenceAuthoring.create_step_transition(%{
  from_step_id: telegram_message.id,
  to_step_id: in_app_nudge.id,
  condition_mode: "always",
  priority: 1
})
|> unwrap.()

setup_transition =
  version.id
  |> SequenceAuthoring.create_step_transition(%{
    from_step_id: in_app_nudge.id,
    to_step_id: setup_sms.id,
    condition_mode: "all",
    priority: 1
  })
  |> unwrap.()

setup_transition.id
|> SequenceAuthoring.create_condition(%{
  transition_id: setup_transition.id,
  condition_type: "hook",
  http_hook_id: setup_status_hook.id,
  operator: "==",
  expected_value: "true"
})
|> unwrap.()

version.id
|> SequenceAuthoring.create_step_transition(%{
  from_step_id: setup_sms.id,
  to_step_id: nil,
  condition_mode: "always",
  priority: 1
})
|> unwrap.()

version.id
|> SequenceAuthoring.validate_sequence_version()
|> unwrap.()

version.id
|> SequenceAuthoring.activate_sequence_version()
|> unwrap.()

lead_sequence =
  %{
    tenant_key: tenant_key,
    name: "Lead nurture demo",
    key: "lead-nurture",
    description:
      "Lead qualification sequence for exercising Elixir hooks, HTTP hooks, predicates, and CRM webhooks.",
    hook_module: "Elixir.DripdropDemo.LeadNurtureHooks",
    active: true,
    metadata: %{"demo" => true}
  }
  |> SequenceAuthoring.create_sequence()
  |> unwrap.()

lead_score_hook =
  lead_sequence.id
  |> DripDrop.create_http_hook(%{
    tenant_key: tenant_key,
    name: "Lead score API",
    key: "lead_score",
    description: "Scores a fixture lead from the demo HTTP hook server.",
    method: "GET",
    url: DripdropDemo.MockHooks.url("/lead-score?lead_id={{ lead_id }}"),
    response_type: "number",
    response_path: "score",
    timeout_ms: 2_000,
    retry_count: 0
  })
  |> unwrap.()

lead_version =
  lead_sequence.id
  |> SequenceAuthoring.create_sequence_version(%{
    version: 1,
    name: "Hook and predicate branches",
    mode: :lifecycle,
    config: %{"demo_time_scale" => Application.fetch_env!(:dripdrop_demo, :demo_time_scale)}
  })
  |> unwrap.()

branch_anchor =
  lead_version.id
  |> SequenceAuthoring.create_step(%{
    name: "Branch decision anchor",
    key: "branch-anchor",
    position: 1,
    channel: "pubsub",
    channel_adapter_id: pubsub_adapter.id,
    timing: %{type: "immediate"},
    template_type: "inline",
    template_content: %{
      "topic" => "demo:lead_nurture",
      "event" => "branch.anchor",
      "payload" => %{
        "title" => "Consulting lead",
        "message" => "{{ first_name }} at {{ company }} asked about {{ interest }}."
      }
    },
    config: %{}
  })
  |> unwrap.()

nurture_email =
  lead_version.id
  |> SequenceAuthoring.create_step(%{
    name: "Nurture email",
    key: "nurture-email",
    position: 2,
    channel: "email",
    channel_adapter_id: email_adapter.id,
    timing: %{type: "delay", delay_amount: 8, delay_unit: "seconds"},
    template_type: "inline",
    template_content: %{
      "subject" => "A few Elixir notes for {{ company }}",
      "text" =>
        "Hi {{ first_name }}, here are a few practical ways to keep Phoenix systems healthy.",
      "html" =>
        "<p>Hi {{ first_name }}, here are a few practical ways to keep Phoenix systems healthy.</p>"
    },
    config: %{}
  })
  |> unwrap.()

slack_notification =
  lead_version.id
  |> SequenceAuthoring.create_step(%{
    name: "Slack notification",
    key: "slack-notification",
    position: 3,
    channel: "slack",
    channel_adapter_id: slack_adapter.id,
    timing: %{type: "delay", delay_amount: 6, delay_unit: "seconds"},
    template_type: "inline",
    template_content: %{
      "channel" => "#sales",
      "text" =>
        "New high-fit consulting lead: {{ company }} is ready for Elixir/Phoenix follow-up."
    },
    config: %{}
  })
  |> unwrap.()

crm_hot =
  lead_version.id
  |> SequenceAuthoring.create_step(%{
    name: "CRM hot-lead update",
    key: "crm-hot-lead",
    position: 4,
    channel: "webhook",
    channel_adapter_id: webhook_adapter.id,
    timing: %{type: "delay", delay_amount: 6, delay_unit: "seconds"},
    template_type: "inline",
    template_content: %{
      "url" => DripdropDemo.MockHooks.url("/crm-update"),
      "method" => "post",
      "body" => %{
        "type" => "crm.lead_qualified",
        "stage" => "sales_ready",
        "source" => "dripdrop_demo",
        "contact" => %{
          "name" => "{{ first_name }}",
          "email" => "{{ email }}",
          "phone" => "{{ sms }}",
          "company" => "{{ company }}"
        },
        "qualification" => %{
          "interest" => "{{ interest }}",
          "budget" => "{{ budget }}",
          "company_size" => "{{ company_size }}"
        }
      }
    },
    config: %{}
  })
  |> unwrap.()

crm_nurture =
  lead_version.id
  |> SequenceAuthoring.create_step(%{
    name: "CRM nurture update",
    key: "crm-nurture",
    position: 5,
    channel: "webhook",
    channel_adapter_id: webhook_adapter.id,
    timing: %{type: "delay", delay_amount: 6, delay_unit: "seconds"},
    template_type: "inline",
    template_content: %{
      "url" => DripdropDemo.MockHooks.url("/crm-update"),
      "method" => "post",
      "body" => %{
        "type" => "crm.lead_nurture",
        "stage" => "nurture",
        "source" => "dripdrop_demo",
        "contact" => %{
          "name" => "{{ first_name }}",
          "email" => "{{ email }}",
          "company" => "{{ company }}"
        },
        "qualification" => %{
          "interest" => "{{ interest }}",
          "budget" => "{{ budget }}",
          "company_size" => "{{ company_size }}"
        }
      }
    },
    config: %{}
  })
  |> unwrap.()

invalid_transition =
  lead_version.id
  |> SequenceAuthoring.create_step_transition(%{
    from_step_id: branch_anchor.id,
    to_step_id: nil,
    condition_mode: "all",
    priority: 1
  })
  |> unwrap.()

invalid_transition.id
|> SequenceAuthoring.create_condition(%{
  transition_id: invalid_transition.id,
  condition_type: "hook",
  hook_function: "verify_email",
  operator: "==",
  expected_value: "false"
})
|> unwrap.()

high_fit_transition =
  lead_version.id
  |> SequenceAuthoring.create_step_transition(%{
    from_step_id: branch_anchor.id,
    to_step_id: slack_notification.id,
    condition_mode: "all",
    priority: 2
  })
  |> unwrap.()

Enum.each(
  [
    %{
      condition_type: "hook",
      hook_function: "verify_email",
      operator: "==",
      expected_value: "true"
    },
    %{
      condition_type: "hook",
      http_hook_id: lead_score_hook.id,
      operator: ">=",
      expected_value: "70"
    },
    %{
      condition_type: "predicate",
      operator: "==",
      config: %{"predicate" => "enrollment.company_size >= 50"}
    }
  ],
  fn attrs ->
    high_fit_transition.id
    |> SequenceAuthoring.create_condition(Map.put(attrs, :transition_id, high_fit_transition.id))
    |> unwrap.()
  end
)

nurture_transition =
  lead_version.id
  |> SequenceAuthoring.create_step_transition(%{
    from_step_id: branch_anchor.id,
    to_step_id: nurture_email.id,
    condition_mode: "all",
    priority: 3
  })
  |> unwrap.()

nurture_transition.id
|> SequenceAuthoring.create_condition(%{
  transition_id: nurture_transition.id,
  condition_type: "hook",
  hook_function: "verify_email",
  operator: "==",
  expected_value: "true"
})
|> unwrap.()

lead_version.id
|> SequenceAuthoring.create_step_transition(%{
  from_step_id: slack_notification.id,
  to_step_id: crm_hot.id,
  condition_mode: "always",
  priority: 1
})
|> unwrap.()

Enum.each([crm_hot, nurture_email, crm_nurture], fn step ->
  to_step_id = if step.id == nurture_email.id, do: crm_nurture.id, else: nil

  lead_version.id
  |> SequenceAuthoring.create_step_transition(%{
    from_step_id: step.id,
    to_step_id: to_step_id,
    condition_mode: "always",
    priority: 1
  })
  |> unwrap.()
end)

lead_version.id
|> SequenceAuthoring.validate_sequence_version()
|> unwrap.()

lead_version.id
|> SequenceAuthoring.activate_sequence_version()
|> unwrap.()

outbound_adapters =
  [
    {"Goodway Alex", "alex@goodway.dev"},
    {"Goodway Jamie", "jamie@goodway.dev"},
    {"Goodway Sam", "sam@goodway.dev"}
  ]
  |> Enum.map(fn {name, email} ->
    create_adapter.(%{
      name: name,
      channel: "email",
      provider: "local",
      is_default: false,
      credentials: %{"from" => "#{name} <#{email}>"},
      daily_cap: 100,
      min_gap_seconds: 2
    })
  end)

outbound_pool =
  %{tenant_key: tenant_key, name: "outbound_pool", on_pin_unavailable: :reassign}
  |> AdapterPools.create_adapter_pool()
  |> unwrap.()

Enum.each(outbound_adapters, fn adapter ->
  outbound_pool
  |> AdapterPools.add_pool_member(%{
    tenant_key: tenant_key,
    adapter_id: adapter.id,
    class: "mailbox",
    weight: 1,
    active: true
  })
  |> unwrap.()
end)

outbound_sequence =
  %{
    tenant_key: tenant_key,
    name: "Goodway Elixir consulting outbound",
    key: "outbound-campaigns",
    description: "Outbound campaign for Goodway Elixir software development consulting.",
    active: true,
    metadata: %{"demo" => true}
  }
  |> SequenceAuthoring.create_sequence()
  |> unwrap.()

outbound_version =
  outbound_sequence.id
  |> SequenceAuthoring.create_sequence_version(%{
    version: 1,
    name: "Goodway consulting campaign",
    mode: :outbound,
    config: %{"pool_id" => outbound_pool.id}
  })
  |> unwrap.()

outbound_1 =
  outbound_version.id
  |> SequenceAuthoring.create_step(%{
    name: "Initial consulting email",
    key: "consulting-intro",
    position: 1,
    channel: "email",
    timing: %{type: "immediate"},
    template_type: "inline",
    template_content: %{
      "subject" => "Phoenix and LiveView help for {{ company }}",
      "text" =>
        "Hi {{ first_name }}, Goodway helps teams stabilize Phoenix apps, clean up LiveView bottlenecks, and ship Elixir features without slowing the product team down. Is that relevant for {{ company }} this quarter?",
      "html" =>
        "<p>Hi {{ first_name }}, Goodway helps teams stabilize Phoenix apps, clean up LiveView bottlenecks, and ship Elixir features without slowing the product team down. Is that relevant for {{ company }} this quarter?</p>"
    },
    config: %{"quiet_hours" => false, "spintax_seed" => "goodway-elixir-intro"}
  })
  |> unwrap.()

outbound_2 =
  outbound_version.id
  |> SequenceAuthoring.create_step(%{
    name: "Threaded follow-up",
    key: "consulting-follow-up",
    position: 2,
    channel: "email",
    timing: %{type: "delay", delay_amount: 10, delay_unit: "seconds"},
    template_type: "inline",
    template_content: %{
      "subject" => "Re: Phoenix and LiveView help for {{ company }}",
      "text" =>
        "A lot of Phoenix teams call us when LiveView screens get state-heavy, background jobs hide production issues, or releases need someone senior to pair with the internal team. Worth comparing notes?",
      "html" =>
        "<p>A lot of Phoenix teams call us when LiveView screens get state-heavy, background jobs hide production issues, or releases need someone senior to pair with the internal team. Worth comparing notes?</p>"
    },
    config: %{"quiet_hours" => false, "reply_behavior" => "pause_enrollment"}
  })
  |> unwrap.()

outbound_3 =
  outbound_version.id
  |> SequenceAuthoring.create_step(%{
    name: "Final bump",
    key: "consulting-final-bump",
    position: 3,
    channel: "email",
    timing: %{type: "delay", delay_amount: 12, delay_unit: "seconds"},
    template_type: "inline",
    template_content: %{
      "subject" => "Re: Phoenix and LiveView help for {{ company }}",
      "text" =>
        "Last note from me. If Phoenix, LiveView, or Elixir reliability work sits with someone else at {{ company }}, who is the better person to ask?",
      "html" =>
        "<p>Last note from me. If Phoenix, LiveView, or Elixir reliability work sits with someone else at {{ company }}, who is the better person to ask?</p>"
    },
    config: %{"quiet_hours" => false, "reply_behavior" => "pause_enrollment"}
  })
  |> unwrap.()

Enum.each(
  [
    {outbound_1, outbound_2},
    {outbound_2, outbound_3},
    {outbound_3, nil}
  ],
  fn {from_step, to_step} ->
    outbound_version.id
    |> SequenceAuthoring.create_step_transition(%{
      from_step_id: from_step.id,
      to_step_id: to_step && to_step.id,
      condition_mode: "always",
      priority: 1
    })
    |> unwrap.()
  end
)

outbound_version.id
|> SequenceAuthoring.validate_sequence_version()
|> unwrap.()

outbound_version.id
|> SequenceAuthoring.activate_sequence_version()
|> unwrap.()

steps_count =
  DripDrop.Step
  |> where([step], step.tenant_key == ^tenant_key)
  |> Repo.aggregate(:count)

IO.puts("Seeded DripDrop demo tenant with #{steps_count} steps across 3 scenarios.")
