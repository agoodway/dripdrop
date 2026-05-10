defmodule DripdropDemoWeb.Scenarios.OnboardingLive do
  @moduledoc """
  Interactive onboarding scenario for exercising DripDrop delivery channels.
  """

  use DripdropDemoWeb, :live_view

  import DripdropDemoWeb.ScenarioComponents

  alias DripDrop.Enrollment
  alias DripdropDemo.ScenarioCatalog
  alias DripdropDemo.Scenarios.Onboarding

  embed_templates("index_html/*")

  @scenario_steps [
    %{
      key: "welcome-email",
      name: "Welcome email",
      channel: "email",
      timing: "Immediate",
      icon: "hero-envelope",
      icon_class: "bg-cyan-500/15 text-cyan-700 dark:text-cyan-200"
    },
    %{
      key: "telegram-message",
      name: "Telegram team alert",
      channel: "telegram",
      timing: "2 sec",
      icon: "hero-paper-airplane",
      icon_class: "bg-blue-500/15 text-blue-700 dark:text-blue-200"
    },
    %{
      key: "in-app-nudge",
      name: "In-app nudge",
      channel: "pubsub",
      timing: "10 sec",
      icon: "hero-bell-alert",
      icon_class: "bg-emerald-500/15 text-emerald-700 dark:text-emerald-200"
    },
    %{
      key: "setup-status-hook",
      name: "Setup status check",
      channel: "HTTP hook",
      timing: "Before SMS",
      icon: "hero-globe-alt",
      icon_class: "bg-indigo-500/15 text-indigo-700 dark:text-indigo-200"
    },
    %{
      key: "setup-sms",
      name: "Setup SMS",
      channel: "sms",
      timing: "12 sec",
      icon: "hero-device-phone-mobile",
      icon_class: "bg-sky-500/15 text-sky-700 dark:text-sky-200"
    }
  ]

  @impl Phoenix.LiveView
  def render(assigns), do: index(assigns)

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(DripdropDemo.PubSub, "demo:in_app")
      Phoenix.PubSub.subscribe(DripdropDemo.PubSub, "demo:telegram")
      Phoenix.PubSub.subscribe(DripdropDemo.PubSub, "demo:onboarding_hooks")
      Phoenix.PubSub.subscribe(DripdropDemo.PubSub, "dripdrop:events")
    end

    scenario = ScenarioCatalog.fetch!(:user_onboarding)

    socket =
      socket
      |> assign(:page_title, "#{scenario.name} Scenario")
      |> assign(:scenario, scenario)
      |> assign(:enrollment, nil)
      |> assign(:executions, [])
      |> assign(:events, [])
      |> assign(:delivered_artifacts, [])
      |> assign(:selected_step_key, nil)
      |> assign(:api_mirror_open?, false)
      |> assign(:sequence_logs_open?, false)
      |> assign(:nudges, [])
      |> assign(:telegrams, [])
      |> assign(:setup_checks, [])
      |> assign(:sequence_available?, Onboarding.sequence_available?())

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("enroll", _params, socket) do
    case Onboarding.enroll() do
      {:ok, enrollment} ->
        {:noreply,
         socket
         |> put_flash(:info, "Onboarding sequence started")
         |> assign(:enrollment, enrollment)
         |> assign(:executions, Onboarding.list_executions(enrollment.id))
         |> assign(:events, [demo_event("dripdrop.demo.enrollment.started", enrollment)])
         |> assign(:delivered_artifacts, [])
         |> assign(:selected_step_key, nil)
         |> assign(:nudges, [])
         |> assign(:telegrams, [])
         |> assign(:setup_checks, [])}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Enrollment failed: #{inspect(reason)}")}
    end
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
  def handle_info({"onboarding.nudge" = event, message}, socket) do
    nudge =
      message
      |> normalize_message()
      |> Map.put(:event, event)
      |> Map.put(:received_at, DateTime.utc_now())

    socket =
      socket
      |> assign(:nudges, [nudge | socket.assigns.nudges])
      |> append_event(%{
        event: "dripdrop.demo.pubsub.received",
        measurements: %{count: 1},
        metadata: nudge
      })

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_info({"telegram.message.sent" = event, message}, socket) do
    telegram =
      message
      |> Map.put(:event, event)
      |> Map.put(:step_key, "telegram-message")

    socket =
      socket
      |> assign(:telegrams, [telegram | socket.assigns.telegrams])
      |> append_event(%{
        event: "dripdrop.demo.pubsub.received",
        measurements: %{count: 1},
        metadata: telegram
      })

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_info({"onboarding.setup_status.checked" = event, message}, socket) do
    check =
      message
      |> Map.put(:event, event)
      |> Map.put(:step_key, "setup-status-hook")
      |> Map.put(:received_at, DateTime.utc_now())

    socket =
      socket
      |> assign(:setup_checks, [check | socket.assigns.setup_checks])
      |> append_event(%{
        event: "dripdrop.demo.http_hook.received",
        measurements: %{count: 1},
        metadata: check
      })

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_info({event, _message}, socket) when is_binary(event), do: {:noreply, socket}

  defp append_dripdrop_event(socket, event, measurements, metadata) do
    events = [
      %{
        event: Enum.join(event, "."),
        measurements: measurements,
        metadata: metadata,
        received_at: DateTime.utc_now()
      }
    ]

    socket =
      case socket.assigns.enrollment do
        %Enrollment{id: enrollment_id} ->
          assign(socket, :executions, Onboarding.list_executions(enrollment_id))

        _none ->
          socket
      end

    socket
    |> maybe_mark_delivered_artifact(event, metadata)
    |> append_event(List.first(events))
  end

  defp maybe_mark_delivered_artifact(socket, [:dripdrop, :dispatch, :sent], %{step_key: step_key}) do
    key = to_string(step_key)

    if key in ["welcome-email", "setup-sms"] do
      update(socket, :delivered_artifacts, &Enum.uniq(&1 ++ [key]))
    else
      socket
    end
  end

  defp maybe_mark_delivered_artifact(socket, _event, _metadata), do: socket

  @event_log_limit 200

  defp append_event(socket, event) do
    update(socket, :events, fn events ->
      Enum.take(events ++ [event], -@event_log_limit)
    end)
  end

  defp current_enrollment_event?(%Enrollment{id: enrollment_id}, %{enrollment_id: enrollment_id}),
    do: true

  defp current_enrollment_event?(_enrollment, _metadata), do: false

  defp demo_event(event, enrollment) do
    %{
      event: event,
      measurements: %{count: 1},
      metadata: %{
        enrollment_id: enrollment.id,
        subscriber_id: enrollment.subscriber_id,
        tenant_key: enrollment.tenant_key
      },
      received_at: DateTime.utc_now()
    }
  end

  defp sequence_steps(executions) do
    Enum.map(@scenario_steps, fn step ->
      execution = Enum.find(executions, &(to_string(&1.step_key) == step.key))

      step
      |> Map.put(:execution, execution)
      |> Map.put(:state, step_state(step.key, execution, executions))
      |> Map.put(:phase, step_phase(step.key, execution, executions))
    end)
  end

  defp step_state("setup-status-hook", _execution, executions) do
    if Enum.any?(executions, &(to_string(&1.step_key) == "in-app-nudge" and sent?(&1))) do
      "eligible"
    else
      "waiting"
    end
  end

  defp step_state(_key, execution, _executions), do: execution_state(execution)

  defp step_phase("setup-status-hook", _execution, executions) do
    if Enum.any?(executions, &(to_string(&1.step_key) == "in-app-nudge" and sent?(&1))) do
      :complete
    else
      :pending
    end
  end

  defp step_phase(_key, execution, _executions), do: execution_phase(execution)

  defp sent?(%{state: state}), do: to_string(state) in ["sent", "delivered", "completed"]

  defp latest_nudge([nudge | _nudges]), do: nudge
  defp latest_nudge([]), do: nil
  defp latest_telegram([telegram | _telegrams]), do: telegram
  defp latest_telegram([]), do: nil
  defp latest_setup_check([setup_check | _setup_checks]), do: setup_check
  defp latest_setup_check([]), do: nil

  defp artifact_delivered?(delivered_artifacts, key), do: key in delivered_artifacts

  defp selected_step_class(selected_step_key, key) when selected_step_key == key do
    "border-info/70 ring-2 ring-info/60 ring-offset-2 ring-offset-base-100 shadow-2xl shadow-info/15"
  end

  defp selected_step_class(_selected_step_key, _key), do: ""

  defp api_mirror_title(nil), do: "Sequence setup"
  defp api_mirror_title(key), do: key

  defp api_mirror_snippet(nil) do
    """
    tenant_key = "demo"

    {:ok, email_adapter} =
      DripDrop.create_channel_adapter(%{
        tenant_key: tenant_key,
        name: "Local email",
        channel: "email",
        provider: "local",
        is_default: true,
        credentials: %{"from" => "DripDrop Demo <demo@dripdrop.dev>"}
      })

    {:ok, sms_adapter} =
      DripDrop.create_channel_adapter(%{
        tenant_key: tenant_key,
        name: "Local SMS",
        channel: "sms",
        provider: "local",
        is_default: true,
        credentials: %{"from" => "+15550001000"}
      })

    {:ok, pubsub_adapter} =
      DripDrop.create_channel_adapter(%{
        tenant_key: tenant_key,
        name: "Phoenix PubSub",
        channel: "pubsub",
        provider: "phoenix_pubsub",
        is_default: true,
        credentials: %{
          "pubsub" => "DripdropDemo.PubSub",
          "topic" => "demo:in_app"
        }
      })

    {:ok, telegram_adapter} =
      DripDrop.create_channel_adapter(%{
        tenant_key: tenant_key,
        name: "Local Telegram",
        channel: "telegram",
        provider: "local",
        is_default: true,
        credentials: %{"chat_id" => "@dripdrop_demo"}
      })

    {:ok, sequence} =
      DripDrop.create_sequence(%{
        tenant_key: tenant_key,
        name: "Onboarding demo",
        key: "onboarding",
        description:
          "Short lifecycle sequence for exercising email, PubSub, HTTP hooks, SMS, and Telegram.",
        active: true,
        metadata: %{"demo" => true}
      })

    {:ok, setup_status_hook} =
      DripDrop.create_http_hook(sequence.id, %{
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

    {:ok, version} =
      DripDrop.create_sequence_version(sequence.id, %{
        version: 1,
        name: "Local demo path",
        mode: :lifecycle,
        config: %{"demo_time_scale" => Application.fetch_env!(:dripdrop_demo, :demo_time_scale)}
      })

    {:ok, welcome_email} =
      DripDrop.create_step(version.id, %{
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

    {:ok, telegram_message} =
      DripDrop.create_step(version.id, %{
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

    {:ok, in_app_nudge} =
      DripDrop.create_step(version.id, %{
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

    {:ok, setup_sms} =
      DripDrop.create_step(version.id, %{
        name: "Setup SMS",
        key: "setup-sms",
        position: 4,
        channel: "sms",
        channel_adapter_id: sms_adapter.id,
        timing: %{type: "delay", delay_amount: 12, delay_unit: "seconds"},
        template_type: "inline",
        template_content: %{
          "body" =>
            "{{ first_name }}, your onboarding setup is complete!"
        },
        config: %{"recipient_key" => "sms"}
      })

    {:ok, _welcome_to_telegram} =
      DripDrop.create_step_transition(version.id, %{
        from_step_id: welcome_email.id,
        to_step_id: telegram_message.id,
        condition_mode: "always",
        priority: 1
      })

    {:ok, _telegram_to_nudge} =
      DripDrop.create_step_transition(version.id, %{
        from_step_id: telegram_message.id,
        to_step_id: in_app_nudge.id,
        condition_mode: "always",
        priority: 1
      })

    {:ok, setup_transition} =
      DripDrop.create_step_transition(version.id, %{
        from_step_id: in_app_nudge.id,
        to_step_id: setup_sms.id,
        condition_mode: "all",
        priority: 1
      })

    {:ok, _setup_condition} =
      DripDrop.create_condition(setup_transition.id, %{
        transition_id: setup_transition.id,
        condition_type: "hook",
        http_hook_id: setup_status_hook.id,
        operator: "==",
        expected_value: "true"
      })

    {:ok, _end_sequence} =
      DripDrop.create_step_transition(version.id, %{
        from_step_id: setup_sms.id,
        to_step_id: nil,
        condition_mode: "always",
        priority: 1
      })

    {:ok, _validated} =
      DripDrop.validate_sequence_version(version.id)

    {:ok, _activated} =
      DripDrop.activate_sequence_version(version.id)

    {:ok, enrollment} =
      DripDrop.enroll(%{
        sequence_id: sequence.id,
        subscriber_type: "demo_user",
        subscriber_id: "onboarding-...",
        tenant_key: tenant_key,
        data: %{
          "first_name" => "Sam",
          "email" => "sam@example.com",
          "sms" => "+15555550101",
          "plan" => "standard",
          "setup_complete" => true
        }
      })
    """
  end

  defp api_mirror_snippet("welcome-email") do
    """
    {:ok, welcome_email} =
      DripDrop.create_step(version.id, %{
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

    {:ok, _welcome_to_telegram} =
      DripDrop.create_step_transition(version.id, %{
        from_step_id: welcome_email.id,
        to_step_id: telegram_message.id,
        condition_mode: "always",
        priority: 1
      })
    """
  end

  defp api_mirror_snippet("in-app-nudge") do
    """
    {:ok, in_app_nudge} =
      DripDrop.create_step(version.id, %{
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

    {:ok, setup_transition} =
      DripDrop.create_step_transition(version.id, %{
        from_step_id: in_app_nudge.id,
        to_step_id: setup_sms.id,
        condition_mode: "all",
        priority: 1
      })

    {:ok, _setup_condition} =
      DripDrop.create_condition(setup_transition.id, %{
        transition_id: setup_transition.id,
        condition_type: "hook",
        http_hook_id: setup_status_hook.id,
        operator: "==",
        expected_value: "true"
      })

    """
  end

  defp api_mirror_snippet("setup-status-hook") do
    """
    {:ok, setup_status_hook} =
      DripDrop.create_http_hook(sequence.id, %{
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

    {:ok, setup_transition} =
      DripDrop.create_step_transition(version.id, %{
        from_step_id: in_app_nudge.id,
        to_step_id: setup_sms.id,
        condition_mode: "all",
        priority: 1
      })

    DripDrop.create_condition(setup_transition.id, %{
      transition_id: setup_transition.id,
      condition_type: "hook",
      http_hook_id: setup_status_hook.id,
      operator: "==",
      expected_value: "true"
    })
    """
  end

  defp api_mirror_snippet("setup-sms") do
    """
    {:ok, setup_sms} =
      DripDrop.create_step(version.id, %{
        name: "Setup SMS",
        key: "setup-sms",
        position: 4,
        channel: "sms",
        channel_adapter_id: sms_adapter.id,
        timing: %{type: "delay", delay_amount: 12, delay_unit: "seconds"},
        template_type: "inline",
        template_content: %{
          "body" =>
            "{{ first_name }}, your onboarding setup is complete!"
        },
        config: %{"recipient_key" => "sms"}
      })

    {:ok, _end_sequence} =
      DripDrop.create_step_transition(version.id, %{
        from_step_id: setup_sms.id,
        to_step_id: nil,
        condition_mode: "always",
        priority: 1
      })
    """
  end

  defp api_mirror_snippet("in-app-nudge-transition") do
    """
    {:ok, setup_transition} =
      DripDrop.create_step_transition(version.id, %{
        from_step_id: in_app_nudge.id,
        to_step_id: setup_sms.id,
        condition_mode: "all",
        priority: 1
      })

    {:ok, _setup_condition} =
      DripDrop.create_condition(setup_transition.id, %{
        transition_id: setup_transition.id,
        condition_type: "hook",
        http_hook_id: setup_status_hook.id,
        operator: "==",
        expected_value: "true"
      })

    """
  end

  defp api_mirror_snippet("telegram-message") do
    """
    {:ok, telegram_message} =
      DripDrop.create_step(version.id, %{
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

    {:ok, _welcome_to_telegram} =
      DripDrop.create_step_transition(version.id, %{
        from_step_id: welcome_email.id,
        to_step_id: telegram_message.id,
        condition_mode: "always",
        priority: 1
      })

    {:ok, _telegram_to_nudge} =
      DripDrop.create_step_transition(version.id, %{
        from_step_id: telegram_message.id,
        to_step_id: in_app_nudge.id,
        condition_mode: "always",
        priority: 1
      })
    """
  end

  defp api_mirror_snippet(_key), do: api_mirror_snippet(nil)

  defp normalize_message(message) when is_map(message) do
    %{
      title: string_or_atom(message, "title") || "In-app nudge",
      message: string_or_atom(message, "message") || inspect(message)
    }
  end

  defp normalize_message(message), do: %{title: "In-app nudge", message: inspect(message)}

  defp string_or_atom(map, "title"), do: Map.get(map, "title") || Map.get(map, :title)
  defp string_or_atom(map, "message"), do: Map.get(map, "message") || Map.get(map, :message)
end
