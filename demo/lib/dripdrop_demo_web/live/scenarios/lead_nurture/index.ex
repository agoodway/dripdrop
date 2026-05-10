defmodule DripdropDemoWeb.Scenarios.LeadNurtureLive do
  @moduledoc """
  Interactive lead nurture scenario for hooks, predicates, branching, and webhooks.
  """

  use DripdropDemoWeb, :live_view

  import DripdropDemoWeb.ScenarioComponents

  alias DripDrop.Enrollment
  alias DripdropDemo.ScenarioCatalog
  alias DripdropDemo.Scenarios.LeadNurture
  alias DripdropDemo.ScenarioSteps

  embed_templates("index_html/*")

  @sequence_key "lead-nurture"
  @step_icons %{
    "email-verification" => "demo-elixir-drop",
    "lead-score-hook" => "hero-globe-alt",
    "nurture-email" => "hero-envelope",
    "slack-notification" => "hero-hashtag",
    "crm-hot-lead" => "hero-bolt",
    "crm-nurture" => "hero-bolt"
  }
  @step_icon_classes %{
    "email-verification" => "bg-purple-500/15 text-purple-700 dark:text-purple-200",
    "lead-score-hook" => "bg-indigo-500/15 text-indigo-700 dark:text-indigo-200",
    "nurture-email" => "bg-cyan-500/15 text-cyan-700 dark:text-cyan-200",
    "slack-notification" => "bg-violet-500/15 text-violet-700 dark:text-violet-200",
    "crm-hot-lead" => "bg-blue-500/15 text-blue-700 dark:text-blue-200",
    "crm-nurture" => "bg-blue-500/15 text-blue-700 dark:text-blue-200"
  }

  @impl Phoenix.LiveView
  def render(assigns), do: index(assigns)

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(DripdropDemo.PubSub, "demo:lead_nurture")
      Phoenix.PubSub.subscribe(DripdropDemo.PubSub, "demo:webhooks")
      Phoenix.PubSub.subscribe(DripdropDemo.PubSub, "dripdrop:events")
    end

    scenario = ScenarioCatalog.fetch!(:lead_nurture)

    socket =
      socket
      |> assign(:page_title, "#{scenario.name} Scenario")
      |> assign(:scenario, scenario)
      |> assign(:enrollment, nil)
      |> assign(:executions, [])
      |> assign(:events, [])
      |> assign(:lead_messages, [])
      |> assign(:webhooks, [])
      |> assign(:selected_step_key, nil)
      |> assign(:api_mirror_open?, false)
      |> assign(:sequence_logs_open?, false)
      |> assign(:sequence_available?, LeadNurture.sequence_available?())
      |> assign(:fixture, :high_fit)

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("enroll", %{"fixture" => fixture}, socket)
      when fixture in ~w(high_fit nurture invalid_email) do
    fixture = String.to_existing_atom(fixture)

    case LeadNurture.enroll(fixture) do
      {:ok, enrollment} ->
        {:noreply,
         socket
         |> put_flash(:info, "Lead nurture sequence started")
         |> assign(:fixture, fixture)
         |> assign(:enrollment, enrollment)
         |> assign(:executions, LeadNurture.list_executions(enrollment.id))
         |> assign(:events, [demo_event("dripdrop.demo.enrollment.started", enrollment)])
         |> assign(:lead_messages, [])
         |> assign(:webhooks, [])
         |> assign(:selected_step_key, nil)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Enrollment failed: #{inspect(reason)}")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("enroll", _params, socket) do
    {:noreply, put_flash(socket, :error, "Unknown fixture")}
  end

  @impl Phoenix.LiveView
  def handle_event("select_step", %{"key" => key}, socket) do
    {:noreply, assign(socket, :selected_step_key, key)}
  end

  @impl Phoenix.LiveView
  def handle_event("toggle_api_mirror", _params, socket) do
    {:noreply, update(socket, :api_mirror_open?, &(!&1))}
  end

  @impl Phoenix.LiveView
  def handle_event("toggle_sequence_logs", _params, socket) do
    {:noreply, update(socket, :sequence_logs_open?, &(!&1))}
  end

  @impl Phoenix.LiveView
  def handle_info({:dripdrop_event, event, measurements, metadata}, socket) do
    if current_enrollment_event?(socket.assigns.enrollment, metadata) do
      {:noreply, append_dripdrop_event(socket, event, measurements, metadata)}
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_info({event, message}, socket)
      when event in ["branch.anchor", "lead.captured"] and is_map(message) do
    message =
      message
      |> normalize_message()
      |> Map.put(:event, event)
      |> Map.put(:received_at, DateTime.utc_now())

    socket =
      socket
      |> assign(:lead_messages, [message | socket.assigns.lead_messages])
      |> append_event(%{
        event: "dripdrop.demo.pubsub.received",
        measurements: %{count: 1},
        metadata: message
      })

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_info({"crm-update.received" = event, payload}, socket) do
    webhook =
      payload
      |> Map.put(:event, event)
      |> Map.put(:step_key, crm_step_key(payload))

    socket =
      socket
      |> assign(:webhooks, [webhook | socket.assigns.webhooks])
      |> append_event(%{
        event: "dripdrop.demo.webhook.received",
        measurements: %{count: 1},
        metadata: webhook
      })

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_info({"slack-alert.received" = event, payload}, socket) do
    {:noreply,
     append_event(socket, %{
       event: "dripdrop.demo.slack.received",
       measurements: %{count: 1},
       metadata: Map.put(payload, :event, event)
     })}
  end

  @impl Phoenix.LiveView
  def handle_info({event, _message}, socket) when is_binary(event), do: {:noreply, socket}

  defp append_dripdrop_event(socket, event, measurements, metadata) do
    socket =
      case socket.assigns.enrollment do
        %Enrollment{id: enrollment_id} ->
          assign(socket, :executions, LeadNurture.list_executions(enrollment_id))

        _none ->
          socket
      end

    append_event(socket, %{
      event: Enum.join(event, "."),
      measurements: measurements,
      metadata: metadata,
      received_at: DateTime.utc_now()
    })
  end

  @event_log_limit 200

  defp append_event(socket, event),
    do:
      update(socket, :events, fn events ->
        Enum.take(events ++ [event], -@event_log_limit)
      end)

  defp current_enrollment_event?(%Enrollment{id: enrollment_id}, %{enrollment_id: enrollment_id}),
    do: true

  defp current_enrollment_event?(_enrollment, _metadata), do: false

  defp demo_event(event, enrollment) do
    %{
      event: event,
      measurements: %{count: 1},
      metadata: %{enrollment_id: enrollment.id, subscriber_id: enrollment.subscriber_id},
      received_at: DateTime.utc_now()
    }
  end

  defp steps(executions, fixture, lead_event) do
    rows =
      @sequence_key
      |> ScenarioSteps.active_steps()
      |> Enum.map(fn step ->
        execution = Enum.find(executions, &(to_string(&1.step_key) == step.key))

        %{
          key: step.key,
          name: step.name,
          channel: ScenarioSteps.format_channel(step.channel),
          timing: ScenarioSteps.format_timing(step.timing),
          icon: Map.get(@step_icons, step.key, "hero-cube-transparent"),
          icon_class: Map.get(@step_icon_classes, step.key),
          state: execution_state(execution),
          phase: execution_phase(execution),
          executed_at: execution && execution.executed_at
        }
      end)

    branch_anchor = Enum.find(rows, &branch_anchor_step?/1)

    [
      email_verification_step(fixture, lead_event, branch_anchor && branch_anchor.executed_at),
      lead_score_hook_step(fixture, lead_event, branch_anchor && branch_anchor.executed_at)
      | Enum.reject(rows, &branch_anchor_step?/1)
    ]
  end

  defp branch_anchor_step?(%{key: key}), do: key in ["branch-anchor", "lead-captured"]
  defp branch_anchor_step?(_step), do: false

  defp branch_anchor?(%{step_key: step_key}),
    do: to_string(step_key) in ["branch-anchor", "lead-captured"]

  defp branch_anchor?(_execution), do: false

  defp latest_lead_event(messages),
    do: Enum.find(messages, &(Map.get(&1, :event) in ["branch.anchor", "lead.captured"]))

  defp latest_webhook([webhook | _webhooks]), do: webhook
  defp latest_webhook([]), do: nil

  defp visible_executions(executions), do: Enum.reject(executions, &branch_anchor?/1)

  defp email_verification_step(fixture, lead_event, executed_at) do
    visible? = not is_nil(lead_event)

    %{
      key: "email-verification",
      name: "GoodVerify email check",
      channel: "Elixir hook",
      timing: "Before branch",
      icon: Map.fetch!(@step_icons, "email-verification"),
      icon_class: Map.fetch!(@step_icon_classes, "email-verification"),
      state: email_verification_step_state(fixture, visible?),
      phase: email_verification_step_phase(fixture, visible?),
      executed_at: if(visible?, do: executed_at)
    }
  end

  defp email_verification_step_state(_fixture, false), do: "waiting"
  defp email_verification_step_state(:invalid_email, true), do: "rejected"
  defp email_verification_step_state(_fixture, true), do: "passed"

  defp email_verification_step_phase(_fixture, false), do: :pending
  defp email_verification_step_phase(:invalid_email, true), do: :issue
  defp email_verification_step_phase(_fixture, true), do: :complete

  defp lead_score_hook_step(fixture, lead_event, executed_at) do
    visible? = not is_nil(lead_event)

    %{
      key: "lead-score-hook",
      name: "Lead score API call",
      channel: "HTTP hook",
      timing: "After email check",
      icon: Map.fetch!(@step_icons, "lead-score-hook"),
      icon_class: Map.fetch!(@step_icon_classes, "lead-score-hook"),
      state: lead_score_step_state(fixture, visible?),
      phase: lead_score_step_phase(fixture, visible?),
      executed_at: if(visible? and fixture != :invalid_email, do: executed_at)
    }
  end

  defp lead_score_step_state(_fixture, false), do: "waiting"
  defp lead_score_step_state(:high_fit, true), do: "score 85"
  defp lead_score_step_state(:nurture, true), do: "score 40"
  defp lead_score_step_state(:invalid_email, true), do: "skipped"

  defp lead_score_step_phase(_fixture, false), do: :pending
  defp lead_score_step_phase(:invalid_email, true), do: :pending
  defp lead_score_step_phase(_fixture, true), do: :complete

  defp email_sent?(executions, key) do
    Enum.any?(executions, &(to_string(&1.step_key) == key and to_string(&1.state) == "sent"))
  end

  defp step_execution(executions, key) do
    Enum.find(executions, &(to_string(&1.step_key) == key))
  end

  defp email_subject(%{payload: payload}), do: payload_value(payload, :subject, "Email")
  defp email_subject(_execution), do: "Email"

  defp email_text(%{payload: payload}), do: payload_value(payload, :text, "")
  defp email_text(_execution), do: ""

  defp slack_channel(%{payload: payload}), do: payload_value(payload, :channel, "#sales")
  defp slack_channel(_execution), do: "#sales"

  defp slack_text(%{payload: payload}), do: payload_value(payload, :text, "")
  defp slack_text(_execution), do: ""

  defp lead_score_status(:high_fit), do: "Score 85 routed to sales"
  defp lead_score_status(:nurture), do: "Score 40 routed to nurture"
  defp lead_score_status(:invalid_email), do: "Skipped after verification failed"

  defp lead_score_value(:high_fit), do: "85"
  defp lead_score_value(:nurture), do: "40"
  defp lead_score_value(:invalid_email), do: "Skipped"

  defp lead_score_route(:high_fit), do: "Slack alert"
  defp lead_score_route(:nurture), do: "Nurture email"
  defp lead_score_route(:invalid_email), do: "Stop sequence"

  defp email_verification_status(:invalid_email), do: "Rejected"
  defp email_verification_status(_fixture), do: "Passed"

  defp goodverify_result_label(:invalid_email), do: "Rejected"
  defp goodverify_result_label(_fixture), do: "Deliverable"

  defp goodverify_result_badge_class(:invalid_email), do: "badge-error"
  defp goodverify_result_badge_class(_fixture), do: "badge-success"

  defp goodverify_result_preview(%Enrollment{data: data}, fixture) do
    email = Map.get(data || %{}, "email", "sam.invalid")
    status = goodverify_deliverability_status(fixture)
    reason = goodverify_deliverability_reason(fixture)

    """
    {:ok,
     %GoodverifyEx.Schemas.EmailVerifyResponse{
       email: #{inspect(email)},
       deliverability: %GoodverifyEx.Schemas.EmailDeliverability{
         status: #{inspect(status)},
         reason: #{inspect(reason)}
       }
     }}
    """
  end

  defp goodverify_result_preview(_enrollment, _fixture), do: "{:error, :missing_enrollment}"

  defp goodverify_deliverability_status(:invalid_email), do: "undeliverable"
  defp goodverify_deliverability_status(_fixture), do: "deliverable"

  defp goodverify_deliverability_reason(:invalid_email), do: "Invalid mailbox"
  defp goodverify_deliverability_reason(_fixture), do: "Valid mailbox"

  defp fixture_button_class(fixture, fixture, %Enrollment{}), do: "btn btn-primary"
  defp fixture_button_class(_current_fixture, _fixture, _enrollment), do: "btn btn-outline"

  defp selected_step_class(selected_step_key, key) when selected_step_key == key do
    "border-info/70 ring-2 ring-info/60 ring-offset-2 ring-offset-base-100 shadow-2xl shadow-info/15"
  end

  defp selected_step_class(_selected_step_key, _key), do: ""

  defp branch_decisions_visible?(lead_event, executions),
    do: lead_event || Enum.any?(executions, &(to_string(&1.state) in ["sent", "skipped"]))

  defp crm_step_key(%{body: %{"stage" => "sales_ready"}}), do: "crm-hot-lead"
  defp crm_step_key(%{body: %{"stage" => "nurture"}}), do: "crm-nurture"
  defp crm_step_key(_payload), do: "crm-update"

  defp normalize_message(message) do
    %{
      title: Map.get(message, "title") || Map.get(message, :title) || "Lead event",
      message: Map.get(message, "message") || Map.get(message, :message) || inspect(message)
    }
  end

  defp payload_value(payload, key, default) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, to_string(key)) || default
  end

  defp payload_value(_payload, _key, default), do: default

  defp api_mirror_title(nil), do: "Full lead nurture sequence"
  defp api_mirror_title(key), do: key

  defp api_mirror_snippet(nil) do
    """
    tenant_key = "demo"

    {:ok, sequence} =
      DripDrop.create_sequence(%{
        tenant_key: tenant_key,
        name: "Lead nurture demo",
        key: "lead-nurture",
        description:
          "Lead qualification sequence for exercising Elixir hooks, HTTP hooks, predicates, and CRM webhooks.",
        hook_module: "Elixir.DripdropDemo.LeadNurtureHooks",
        active: true,
        metadata: %{"demo" => true}
      })

    {:ok, lead_score_hook} =
      DripDrop.create_http_hook(sequence.id, %{
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

    {:ok, version} =
      DripDrop.create_sequence_version(sequence.id, %{
        version: 1,
        name: "Hook and predicate branches",
        mode: :lifecycle,
        config: %{"demo_time_scale" => Application.fetch_env!(:dripdrop_demo, :demo_time_scale)}
      })

    {:ok, slack_adapter} =
      DripDrop.create_channel_adapter(%{
        tenant_key: tenant_key,
        name: "Mock Slack",
        channel: "slack",
        provider: "webhook",
        credentials: %{"url" => DripdropDemo.MockHooks.url("/slack-alert")},
        active: true
      })

    {:ok, branch_anchor} =
      DripDrop.create_step(version.id, %{
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
        }
      })

    {:ok, nurture_email} =
      DripDrop.create_step(version.id, %{
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
        }
      })

    {:ok, slack_notification} =
      DripDrop.create_step(version.id, %{
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
        }
      })

    {:ok, crm_hot} =
      DripDrop.create_step(version.id, %{
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
        }
      })

    {:ok, crm_nurture} =
      DripDrop.create_step(version.id, %{
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
        }
      })

    # Decision 1: direct Elixir module hook.
    #
    # DripDrop calls DripdropDemo.LeadNurtureHooks.handle_hook/3.
    # That host hook can call the GoodVerify.dev Elixir client directly:
    #
    # client = GoodverifyEx.client(api_key: System.fetch_env!("GOODVERIFY_API_KEY"))
    # {:ok, result} = GoodverifyEx.verify_email(client, %{email: enrollment.data["email"]})
    # result.deliverability.status == "deliverable"

    {:ok, invalid_transition} =
      DripDrop.create_step_transition(version.id, %{
        from_step_id: branch_anchor.id,
        to_step_id: nil,
        condition_mode: "all",
        priority: 1
      })

    DripDrop.create_condition(invalid_transition.id, %{
      condition_type: "hook",
      hook_function: "verify_email",
      operator: "==",
      expected_value: "false"
    })

    {:ok, high_fit_transition} =
      DripDrop.create_step_transition(version.id, %{
        from_step_id: branch_anchor.id,
        to_step_id: slack_notification.id,
        condition_mode: "all",
        priority: 2
      })

    DripDrop.create_condition(high_fit_transition.id, %{
      condition_type: "hook",
      hook_function: "verify_email",
      operator: "==",
      expected_value: "true"
    })

    # Decision 2: external HTTP hook.
    #
    # DripDrop calls the configured lead_score_hook and compares
    # response.score against the condition below.

    DripDrop.create_condition(high_fit_transition.id, %{
      condition_type: "hook",
      http_hook_id: lead_score_hook.id,
      operator: ">=",
      expected_value: "70"
    })

    DripDrop.create_condition(high_fit_transition.id, %{
      condition_type: "predicate",
      operator: "==",
      config: %{"predicate" => "enrollment.company_size >= 50"}
    })

    {:ok, nurture_transition} =
      DripDrop.create_step_transition(version.id, %{
        from_step_id: branch_anchor.id,
        to_step_id: nurture_email.id,
        condition_mode: "all",
        priority: 3
      })

    DripDrop.create_condition(nurture_transition.id, %{
      condition_type: "hook",
      hook_function: "verify_email",
      operator: "==",
      expected_value: "true"
    })

    DripDrop.create_step_transition(version.id, %{
      from_step_id: slack_notification.id,
      to_step_id: crm_hot.id,
      condition_mode: "always",
      priority: 1
    })

    DripDrop.create_step_transition(version.id, %{
      from_step_id: nurture_email.id,
      to_step_id: crm_nurture.id,
      condition_mode: "always",
      priority: 1
    })

    for terminal_step <- [crm_hot, crm_nurture] do
      DripDrop.create_step_transition(version.id, %{
        from_step_id: terminal_step.id,
        to_step_id: nil,
        condition_mode: "always",
        priority: 1
      })
    end

    {:ok, _validated} = DripDrop.validate_sequence_version(version.id)
    {:ok, _activated} = DripDrop.activate_sequence_version(version.id)
    """
  end

  defp api_mirror_snippet("slack-notification") do
    """
    {:ok, high_fit_transition} =
      DripDrop.create_step_transition(version.id, %{
        from_step_id: branch_anchor.id,
        to_step_id: slack_notification.id,
        condition_mode: "all",
        priority: 2
      })

    DripDrop.create_condition(high_fit_transition.id, %{
      condition_type: "hook",
      hook_function: "verify_email",
      operator: "==",
      expected_value: "true"
    })

    DripDrop.create_condition(high_fit_transition.id, %{
      condition_type: "hook",
      http_hook_id: lead_score_hook.id,
      operator: ">=",
      expected_value: "70"
    })

    DripDrop.create_condition(high_fit_transition.id, %{
      condition_type: "predicate",
      operator: "==",
      config: %{"predicate" => "enrollment.company_size >= 50"}
    })

    {:ok, slack_notification} =
      DripDrop.create_step(version.id, %{
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
        }
      })

    DripDrop.create_step_transition(version.id, %{
      from_step_id: slack_notification.id,
      to_step_id: crm_hot.id,
      condition_mode: "always",
      priority: 1
    })
    """
  end

  defp api_mirror_snippet("nurture-email") do
    """
    {:ok, nurture_transition} =
      DripDrop.create_step_transition(version.id, %{
        from_step_id: branch_anchor.id,
        to_step_id: nurture_email.id,
        condition_mode: "all",
        priority: 3
      })

    DripDrop.create_condition(nurture_transition.id, %{
      condition_type: "hook",
      hook_function: "verify_email",
      operator: "==",
      expected_value: "true"
    })

    {:ok, nurture_email} =
      DripDrop.create_step(version.id, %{
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

    DripDrop.create_step_transition(version.id, %{
      from_step_id: nurture_email.id,
      to_step_id: crm_nurture.id,
      condition_mode: "always",
      priority: 1
    })
    """
  end

  defp api_mirror_snippet("crm-hot-lead") do
    """
    DripDrop.create_step_transition(version.id, %{
      from_step_id: slack_notification.id,
      to_step_id: crm_hot.id,
      condition_mode: "always",
      priority: 1
    })

    {:ok, crm_hot_lead} =
      DripDrop.create_step(version.id, %{
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

    DripDrop.create_step_transition(version.id, %{
      from_step_id: crm_hot_lead.id,
      to_step_id: nil,
      condition_mode: "always",
      priority: 1
    })
    """
  end

  defp api_mirror_snippet("crm-nurture") do
    """
    DripDrop.create_step_transition(version.id, %{
      from_step_id: nurture_email.id,
      to_step_id: crm_nurture.id,
      condition_mode: "always",
      priority: 1
    })

    {:ok, crm_nurture} =
      DripDrop.create_step(version.id, %{
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

    DripDrop.create_step_transition(version.id, %{
      from_step_id: crm_nurture.id,
      to_step_id: nil,
      condition_mode: "always",
      priority: 1
    })
    """
  end

  defp api_mirror_snippet("email-verification") do
    """
    defmodule DripdropDemo.LeadNurtureHooks do
      @behaviour DripDrop.HookBehavior

      def handle_hook(:verify_email, enrollment, _context) do
        client =
          GoodverifyEx.client(
            base_url: "https://goodverify.dev",
            api_key: System.fetch_env!("GOODVERIFY_API_KEY")
          )

        with {:ok, result} <-
               GoodverifyEx.verify_email(client, %{email: enrollment.data["email"]}) do
          {:ok, result.deliverability.status == "deliverable"}
        end
      end
    end

    {:ok, invalid_transition} =
      DripDrop.create_step_transition(version.id, %{
        from_step_id: branch_anchor.id,
        to_step_id: nil,
        condition_mode: "all",
        priority: 1
      })

    DripDrop.create_condition(invalid_transition.id, %{
      condition_type: "hook",
      hook_function: "verify_email",
      operator: "==",
      expected_value: "false"
    })
    """
  end

  defp api_mirror_snippet("lead-score-hook") do
    """
    {:ok, lead_score_hook} =
      DripDrop.create_http_hook(sequence.id, %{
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

    DripDrop.create_condition(high_fit_transition.id, %{
      condition_type: "hook",
      http_hook_id: lead_score_hook.id,
      operator: ">=",
      expected_value: "70"
    })

    DripDrop.create_condition(high_fit_transition.id, %{
      condition_type: "predicate",
      operator: "==",
      config: %{"predicate" => "enrollment.company_size >= 50"}
    })
    """
  end

  defp api_mirror_snippet(_key), do: api_mirror_snippet(nil)
end
