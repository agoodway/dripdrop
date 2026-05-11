defmodule DripdropDemoWeb.Scenarios.OutboundLive do
  @moduledoc """
  Interactive outbound campaigns scenario for sender pools and threaded email campaigns.
  """

  use DripdropDemoWeb, :live_view

  import DripdropDemoWeb.OutboundComponents
  import DripdropDemoWeb.ScenarioComponents

  alias DripdropDemo.ScenarioCatalog
  alias DripdropDemo.Scenarios.Outbound
  alias DripdropDemo.Scenarios.Outbound.Simulators
  alias DripdropDemo.ScenarioSteps

  embed_templates("index_html/*")

  @sequence_key "outbound-campaigns"
  @step_icons %{
    "consulting-intro" => "hero-envelope",
    "consulting-follow-up" => "hero-envelope-open",
    "consulting-final-bump" => "hero-envelope-open"
  }
  @step_icon_classes %{
    "consulting-intro" => "bg-cyan-500/15 text-cyan-700 dark:text-cyan-200",
    "consulting-follow-up" => "bg-cyan-500/15 text-cyan-700 dark:text-cyan-200",
    "consulting-final-bump" => "bg-cyan-500/15 text-cyan-700 dark:text-cyan-200"
  }
  @autoplay_base_ms 1_000

  @impl Phoenix.LiveView
  def render(assigns), do: index(assigns)

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    pool_members =
      if connected?(socket), do: Outbound.list_pool_members(), else: []

    if connected?(socket) do
      Phoenix.PubSub.subscribe(DripdropDemo.PubSub, "dripdrop:events")
      subscribe_adapter_topics(pool_members)
      Process.send_after(self(), :tick, 1_000)
    end

    scenario = ScenarioCatalog.fetch!(:outbound_campaigns)

    socket =
      socket
      |> assign(:page_title, "#{scenario.name} Scenario")
      |> assign(:scenario, scenario)
      |> assign(:enrollments, [])
      |> assign(:pool_members, pool_members)
      |> assign(:events, [])
      |> assign(:selected_enrollment_id, nil)
      |> assign(:selected_step_key, nil)
      |> assign(:now, DateTime.utc_now(:second))
      |> assign(:autoplay_timers, %{})
      |> assign(:triggered_outcome_ids, MapSet.new())
      |> assign(:api_mirror_open?, false)
      |> assign(:sequence_logs_open?, false)
      |> assign(:sequence_available?, Outbound.sequence_available?())
      |> assign_thread()

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("enroll", _params, socket) do
    case Outbound.enroll_prospects() do
      {:ok, enrollments} ->
        enrollment_rows = Outbound.list_enrollments(Enum.map(enrollments, & &1.id))

        {:noreply,
         socket
         |> put_flash(:info, "Outbound campaign started")
         |> assign(:enrollments, enrollment_rows)
         |> assign(:pool_members, Outbound.list_pool_members())
         |> assign(:selected_enrollment_id, enrollments |> List.first() |> then(&(&1 && &1.id)))
         |> assign(:selected_step_key, nil)
         |> assign(:events, demo_events(enrollments))
         |> assign_thread()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Outbound enrollment failed: #{inspect(reason)}")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("select_enrollment", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_enrollment_id, id)
     |> assign_thread()}
  end

  @impl Phoenix.LiveView
  def handle_event("set_sender_state", %{"id" => id, "state" => state}, socket) do
    with {:ok, state} <- sender_state_from_param(state),
         :ok <- Simulators.set_adapter_state(id, state) do
      {:noreply, refresh_outbound_state(socket)}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Sender update failed: #{inspect(reason)}")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("reset_capacity_today", _params, socket) do
    case Outbound.reset_capacity_today() do
      {:ok, %{sent_events: sent_events}} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Sender capacity reset (#{sent_events} sent events moved out of today)"
         )
         |> refresh_outbound_state()
         |> assign_thread()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Capacity reset failed: #{inspect(reason)}")}
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
    tracked_ids = Enum.map(socket.assigns.enrollments, & &1.id)
    tracked_adapter_ids = Enum.map(socket.assigns.pool_members, & &1.id)

    socket =
      cond do
        metadata[:enrollment_id] in tracked_ids ->
          socket
          |> refresh_outbound_state()
          |> maybe_schedule_autoplay_from_event(event, metadata)
          |> append_event(%{
            event: Enum.join(event, "."),
            measurements: measurements,
            metadata: metadata,
            received_at: DateTime.utc_now()
          })
          |> assign_thread()

        metadata[:adapter_id] in tracked_adapter_ids ->
          socket
          |> assign(:pool_members, Outbound.list_pool_members())
          |> append_event(%{
            event: Enum.join(event, "."),
            measurements: measurements,
            metadata: metadata,
            received_at: DateTime.utc_now()
          })

        true ->
          socket
      end

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 1_000)
    {:noreply, assign(socket, :now, DateTime.utc_now(:second))}
  end

  @impl Phoenix.LiveView
  def handle_info({:autoplay_outcome, enrollment_id}, socket) do
    socket = drop_autoplay_timer(socket, enrollment_id)

    case Enum.find(socket.assigns.enrollments, &(&1.id == enrollment_id)) do
      %{outcome: :ghost} ->
        {:noreply, mark_triggered(socket, enrollment_id)}

      %{outcome: outcome} ->
        case Simulators.trigger(enrollment_id, outcome) do
          :ok ->
            {:noreply,
             socket
             |> mark_triggered(enrollment_id)
             |> refresh_outbound_state()
             |> assign_thread()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Campaign outcome failed: #{inspect(reason)}")}
        end

      nil ->
        {:noreply, socket}
    end
  end

  defp refresh_outbound_state(socket) do
    tracked_ids = Enum.map(socket.assigns.enrollments, & &1.id)

    if tracked_ids == [] do
      assign(socket, :pool_members, Outbound.list_pool_members())
    else
      enrollments = Outbound.list_enrollments(tracked_ids)

      socket
      |> assign(:enrollments, enrollments)
      |> assign(:pool_members, Outbound.list_pool_members())
      |> assign(
        :selected_enrollment_id,
        preferred_enrollment_id(enrollments, socket.assigns.selected_enrollment_id)
      )
    end
  end

  defp maybe_schedule_autoplay_from_event(socket, [:dripdrop, :dispatch, :sent], %{
         enrollment_id: enrollment_id,
         step_key: "consulting-intro"
       }) do
    maybe_schedule_autoplay(socket, enrollment_id)
  end

  defp maybe_schedule_autoplay_from_event(socket, _event, _metadata), do: socket

  defp maybe_schedule_autoplay(socket, enrollment_id) do
    triggered? = MapSet.member?(socket.assigns.triggered_outcome_ids, enrollment_id)
    queued? = Map.has_key?(socket.assigns.autoplay_timers, enrollment_id)
    enrollment = Enum.find(socket.assigns.enrollments, &(&1.id == enrollment_id))

    if triggered? or queued? or is_nil(enrollment) or enrollment.outcome == :ghost do
      socket
    else
      ref =
        Process.send_after(
          self(),
          {:autoplay_outcome, enrollment_id},
          @autoplay_base_ms + :rand.uniform(2_000)
        )

      update(socket, :autoplay_timers, &Map.put(&1, enrollment_id, ref))
    end
  end

  defp drop_autoplay_timer(socket, enrollment_id) do
    update(socket, :autoplay_timers, &Map.delete(&1, enrollment_id))
  end

  defp mark_triggered(socket, enrollment_id) do
    update(socket, :triggered_outcome_ids, &MapSet.put(&1, enrollment_id))
  end

  defp sender_state_from_param("active"), do: {:ok, :active}
  defp sender_state_from_param("resting"), do: {:ok, :resting}
  defp sender_state_from_param("probing"), do: {:ok, :probing}
  defp sender_state_from_param("ramping"), do: {:ok, :ramping}
  defp sender_state_from_param(_state), do: {:error, :unknown_sender_state}

  # Pool membership is stable for the demo (`reset_capacity_today` only updates
  # existing adapters, never adds/removes). If membership becomes dynamic, add
  # re-subscribe logic here that diffs old vs new ids.
  defp subscribe_adapter_topics(pool_members) do
    Enum.each(pool_members, fn member ->
      Phoenix.PubSub.subscribe(DripdropDemo.PubSub, "adapter:#{member.id}")
    end)
  end

  defp assign_thread(socket) do
    selected =
      selected_enrollment(socket.assigns.enrollments, socket.assigns.selected_enrollment_id)

    thread_rows = Outbound.latest_thread_rows(selected && selected.id)
    step_rows = sequence_steps(thread_rows)

    socket
    |> assign(:selected, selected)
    |> assign(:thread_rows, thread_rows)
    |> assign(:step_rows, step_rows)
  end

  @event_log_limit 200

  defp append_event(socket, event),
    do:
      update(socket, :events, fn events ->
        Enum.take(events ++ [event], -@event_log_limit)
      end)

  defp sequence_steps(rows) when is_list(rows) do
    @sequence_key
    |> ScenarioSteps.active_steps()
    |> Enum.map(fn step ->
      execution = Enum.find(rows, &(to_string(&1.step_key) == step.key))

      %{
        key: step.key,
        name: step.name,
        channel: ScenarioSteps.format_channel(step.channel),
        timing: ScenarioSteps.format_timing(step.timing),
        icon: Map.get(@step_icons, step.key, "hero-cube-transparent"),
        icon_class: Map.get(@step_icon_classes, step.key),
        state: execution_state(execution),
        phase: execution_phase(execution),
        executed_at: executed_at(execution)
      }
    end)
  end

  defp demo_events(enrollments) do
    Enum.map(enrollments, fn enrollment ->
      %{
        event: "dripdrop.demo.enrollment.started",
        measurements: %{count: 1},
        metadata: %{
          enrollment_id: enrollment.id,
          adapter_id: enrollment.adapter_id,
          effective_mode: enrollment.effective_mode
        },
        received_at: DateTime.utc_now()
      }
    end)
  end

  defp selected_enrollment(enrollments, nil), do: List.first(enrollments)

  defp selected_enrollment(enrollments, id),
    do: Enum.find(enrollments, &(&1.id == id)) || List.first(enrollments)

  defp preferred_enrollment_id([], _selected_id), do: nil

  defp preferred_enrollment_id(enrollments, selected_id) do
    selected = selected_enrollment(enrollments, selected_id)
    selected && selected.id
  end

  defp executed_at(%{executed_at: executed_at}), do: executed_at
  defp executed_at(_execution), do: nil

  defp sent_email_rows(rows) do
    Enum.filter(rows, &(to_string(&1.state) == "sent" and is_map(&1.payload)))
  end

  defp email_subject(%{payload: payload}), do: payload_value(payload, :subject, "Outbound email")
  defp email_subject(_row), do: "Outbound email"

  defp email_text(%{payload: payload}), do: payload_value(payload, :text, "")
  defp email_text(_row), do: ""

  defp email_recipient(%{recipient: recipient}) when is_binary(recipient) and recipient != "",
    do: recipient

  defp email_recipient(_row), do: "prospect"

  defp email_sender(%{response: response}) when is_map(response) do
    response
    |> Map.get("from")
    |> case do
      sender when is_binary(sender) and sender != "" -> sender
      _sender -> "Goodway"
    end
  end

  defp email_sender(_row), do: "Goodway"

  defp selected_step_class(selected_step_key, key) when selected_step_key == key do
    "border-info/70 ring-2 ring-info/60 ring-offset-2 ring-offset-base-100 shadow-2xl shadow-info/15"
  end

  defp selected_step_class(_selected_step_key, _key), do: ""

  defp payload_value(payload, key, default) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, to_string(key)) || default
  end

  defp payload_value(_payload, _key, default), do: default

  defp blank_to_dash(nil), do: "-"
  defp blank_to_dash(""), do: "-"
  defp blank_to_dash(value), do: value

  defp api_mirror_title(nil), do: "Full outbound campaign sequence"
  defp api_mirror_title(key), do: key

  defp api_mirror_snippet(nil) do
    """
    tenant_key = "demo"

    sender_attrs = [
      {"Goodway Alex", "alex@goodway.dev"},
      {"Goodway Jamie", "jamie@goodway.dev"},
      {"Goodway Sam", "sam@goodway.dev"}
    ]

    senders =
      Enum.map(sender_attrs, fn {name, email} ->
        {:ok, adapter} =
          DripDrop.create_channel_adapter(%{
            tenant_key: tenant_key,
            name: name,
            channel: "email",
            provider: "local",
            is_default: false,
            credentials: %{"from" => "\#{name} <\#{email}>"},
            daily_cap: #{Outbound.daily_cap_default()},
            min_gap_seconds: #{Outbound.min_gap_default()}
          })

        adapter
      end)

    {:ok, pool} =
      DripDrop.create_adapter_pool(%{
        tenant_key: tenant_key,
        name: "outbound_pool",
        on_pin_unavailable: :reassign
      })

    Enum.each(senders, fn adapter ->
      {:ok, _member} =
        DripDrop.add_pool_member(pool, %{
          tenant_key: tenant_key,
          adapter_id: adapter.id,
          class: "mailbox",
          weight: 1,
          active: true
        })
    end)

    {:ok, sequence} =
      DripDrop.create_sequence(%{
        tenant_key: tenant_key,
        name: "Goodway Elixir consulting outbound",
        key: "outbound-campaigns",
        description: "Outbound campaign for Goodway Elixir software development consulting.",
        active: true,
        metadata: %{"demo" => true}
      })

    {:ok, version} =
      DripDrop.create_sequence_version(sequence.id, %{
        version: 1,
        name: "Goodway consulting campaign",
        mode: :outbound,
        config: %{"pool_id" => pool.id}
      })

    {:ok, intro} =
      DripDrop.create_step(version.id, %{
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

    {:ok, follow_up} =
      DripDrop.create_step(version.id, %{
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

    {:ok, final_bump} =
      DripDrop.create_step(version.id, %{
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

    for {from_step, to_step} <- [
          {intro, follow_up},
          {follow_up, final_bump},
          {final_bump, nil}
        ] do
      {:ok, _transition} =
        DripDrop.create_step_transition(version.id, %{
          from_step_id: from_step.id,
          to_step_id: to_step && to_step.id,
          condition_mode: "always",
          priority: 1
        })
    end

    {:ok, _validated} = DripDrop.validate_sequence_version(version.id)
    {:ok, _activated} = DripDrop.activate_sequence_version(version.id)

    for {first_name, company, email} <- [
          {"Mia", "Northstar SaaS", "mia@northstar.example"},
          {"Jordan", "Atlas Metrics", "jordan@atlas.example"},
          {"Priya", "SignalOps", "priya@signalops.example"},
          {"Eli", "Runway Data", "eli@runway.example"},
          {"Nora", "StackPilot", "nora@stackpilot.example"},
          {"Theo", "OpsCanvas", "theo@opscanvas.example"},
          {"Avery", "MetricForge", "avery@metricforge.example"},
          {"Quinn", "LaunchGrid", "quinn@launchgrid.example"}
        ] do
      DripDrop.enroll(%{
        sequence_id: sequence.id,
        subscriber_type: "prospect",
        subscriber_id: "goodway-prospect-\#{System.unique_integer([:positive])}",
        tenant_key: tenant_key,
        data: %{
          "first_name" => first_name,
          "company" => company,
          "email" => email,
          "interest" => "Elixir software development consulting"
        }
      })
    end
    """
  end

  defp api_mirror_snippet("consulting-intro") do
    """
    {:ok, intro} =
      DripDrop.create_step(version.id, %{
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

    DripDrop.create_step_transition(version.id, %{
      from_step_id: intro.id,
      to_step_id: follow_up.id,
      condition_mode: "always",
      priority: 1
    })
    """
  end

  defp api_mirror_snippet("consulting-follow-up") do
    """
    {:ok, follow_up} =
      DripDrop.create_step(version.id, %{
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

    DripDrop.create_step_transition(version.id, %{
      from_step_id: follow_up.id,
      to_step_id: final_bump.id,
      condition_mode: "always",
      priority: 1
    })
    """
  end

  defp api_mirror_snippet("consulting-final-bump") do
    """
    {:ok, final_bump} =
      DripDrop.create_step(version.id, %{
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

    DripDrop.create_step_transition(version.id, %{
      from_step_id: final_bump.id,
      to_step_id: nil,
      condition_mode: "always",
      priority: 1
    })
    """
  end

  defp api_mirror_snippet(_key), do: api_mirror_snippet(nil)
end
