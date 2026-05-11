defmodule DripdropDemoWeb.OutboundComponents do
  @moduledoc """
  Outbound-campaign specific UI components.
  """

  use DripdropDemoWeb, :html

  attr(:outcome, :atom, required: true)
  attr(:class, :string, default: nil)

  def outcome_badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm gap-1 whitespace-nowrap",
      outcome_badge_class(@outcome),
      @class
    ]}>
      <.icon name={outcome_icon(@outcome)} class="size-3.5" />
      {outcome_label(@outcome)}
    </span>
    """
  end

  attr(:members, :list, required: true)
  attr(:now, :any, required: true)
  attr(:rest, :global)

  def sender_pool_panel(assigns) do
    ~H"""
    <section
      {@rest}
      class="rounded-lg border border-base-300 bg-base-100 p-4 shadow-xl shadow-cyan-950/10"
    >
      <div class="mb-4 flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h2 class="text-sm font-black uppercase tracking-wide text-base-content/70">
            Sender pool
          </h2>
          <p class="mt-1 text-xs text-base-content/50">
            Health, capacity, and per-mailbox spacing update as outcomes run.
          </p>
        </div>
        <div class="flex shrink-0 items-center gap-2">
          <button
            type="button"
            class="btn btn-outline btn-xs"
            phx-click="reset_capacity_today"
          >
            Reset capacity <.icon name="hero-arrow-path" class="size-3.5" />
          </button>
        </div>
      </div>
      <div class="grid gap-3 lg:grid-cols-3">
        <div
          :for={member <- @members}
          class="rounded-lg border border-base-300 bg-base-200/50 p-3"
          id={"sender-#{member.id}"}
        >
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <div class="truncate text-sm font-bold text-base-content">{member.name}</div>
              <div class="mt-1 truncate text-[11px] text-base-content/55">
                {member.sender_email || "No mailbox configured"}
              </div>
              <div class="mt-1">
                <span class="badge badge-outline badge-xs">{provider_label(member.provider)}</span>
              </div>
            </div>
            <.sender_health_pill state={member.health_state} paused_until={member.paused_until} />
          </div>
          <div class="mt-3 space-y-3">
            <.capacity_bar
              sent={member.sent_today}
              cap={member.effective_cap_today || member.daily_cap}
            />
            <.min_gap_meter
              last_sent_at={member.last_send_at}
              min_gap_seconds={member.min_gap_seconds}
              now={@now}
            />
            <div :if={member.paused_reason} class="text-[11px] text-warning">
              Paused: {member.paused_reason}
            </div>
            <.sender_control_strip adapter_id={member.id} />
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr(:state, :atom, default: nil)
  attr(:paused_until, :any, default: nil)

  def sender_health_pill(assigns) do
    ~H"""
    <span class={["badge badge-sm gap-1", health_class(@state, @paused_until)]}>
      <span class="size-1.5 rounded-full bg-current"></span>
      {health_label(@state, @paused_until)}
    </span>
    """
  end

  attr(:sent, :integer, default: 0)
  attr(:cap, :integer, default: nil)

  def capacity_bar(assigns) do
    assigns = assign(assigns, :pct, capacity_pct(assigns.sent, assigns.cap))

    ~H"""
    <div>
      <div class="mb-1 flex items-center justify-between text-[11px] text-base-content/50">
        <span>Capacity today</span>
        <span>{@sent}/{@cap || "∞"}</span>
      </div>
      <div class="h-2 overflow-hidden rounded-full bg-base-300">
        <div class="h-full rounded-full bg-primary transition-all" style={"width: #{@pct}%"}></div>
      </div>
    </div>
    """
  end

  attr(:last_sent_at, :any, default: nil)
  attr(:min_gap_seconds, :integer, default: nil)
  attr(:now, :any, required: true)

  def min_gap_meter(assigns) do
    assigns =
      assign(
        assigns,
        :gap_label,
        min_gap_label(assigns.last_sent_at, assigns.min_gap_seconds, assigns.now)
      )

    ~H"""
    <div class="flex items-center justify-between rounded-md bg-base-100 px-2 py-1.5 text-[11px]">
      <span class="font-semibold text-base-content/45">Min gap</span>
      <span class="font-bold text-base-content/70">{@gap_label}</span>
    </div>
    """
  end

  attr(:defer, :map, default: nil)
  attr(:class, :string, default: nil)

  def defer_reason_badge(%{defer: nil} = assigns), do: ~H""

  def defer_reason_badge(assigns) do
    ~H"""
    <span class={["badge badge-warning badge-sm gap-1", @class]}>
      <.icon name="hero-clock" class="size-3.5" />
      {defer_label(@defer)}
    </span>
    """
  end

  attr(:sender, :string, default: nil)
  attr(:email, :string, default: nil)
  attr(:provider, :string, default: nil)
  attr(:class, :string, default: nil)

  def pin_breadcrumb(assigns) do
    ~H"""
    <span class={[
      "grid min-w-0 grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-1.5 text-xs text-base-content/50",
      @class
    ]}>
      <span class="size-2 shrink-0 rounded-full bg-primary"></span>
      <span class="block min-w-0 truncate">
        {@sender || "Unpinned"}
        <span :if={@email} class="text-base-content/40">&lt;{@email}&gt;</span>
      </span>
      <span :if={@provider} class="badge badge-outline badge-xs shrink-0">
        {provider_label(@provider)}
      </span>
    </span>
    """
  end

  attr(:enrollment, :map, required: true)
  attr(:selected?, :boolean, default: false)
  attr(:rest, :global)

  def prospect_card(assigns) do
    ~H"""
    <div
      {@rest}
      role="button"
      tabindex="0"
      phx-click="select_enrollment"
      phx-value-id={@enrollment.id}
      data-enrollment-id={@enrollment.id}
      class={[
        "group flex min-h-48 flex-col rounded-lg border bg-base-100 p-3 text-left shadow-lg shadow-cyan-950/5 transition-all hover:-translate-y-0.5 hover:border-info/60",
        if(@selected?,
          do: "border-info/70 ring-2 ring-info/50 ring-offset-2 ring-offset-base-100",
          else: "border-base-300"
        )
      ]}
    >
      <div class="flex items-start justify-between gap-2">
        <div class="min-w-0">
          <div class="truncate text-sm font-black text-base-content">{@enrollment.first_name}</div>
          <div class="truncate text-xs text-base-content/50">{@enrollment.company}</div>
        </div>
        <.outcome_badge outcome={@enrollment.outcome} class="max-w-[9rem]" />
      </div>
      <div class="mt-3 min-w-0 space-y-2">
        <.pin_breadcrumb
          sender={@enrollment.adapter_name}
          email={@enrollment.sender_email}
          provider={@enrollment.adapter_provider}
        />
        <.defer_reason_badge defer={@enrollment.last_defer} />
      </div>
      <div class="mt-auto border-t border-base-300/70 pt-3">
        <div class="text-[10px] font-black uppercase tracking-wide text-base-content/35">
          Scenario
        </div>
        <p class="mt-1 text-xs leading-5 text-base-content/65">
          {outcome_description(@enrollment.outcome)}
        </p>
      </div>
    </div>
    """
  end

  attr(:adapter_id, :string, required: true)

  def sender_control_strip(assigns) do
    ~H"""
    <div class="grid grid-cols-3 gap-1">
      <button
        class="btn btn-ghost btn-xs"
        phx-click="set_sender_state"
        phx-value-id={@adapter_id}
        phx-value-state="active"
      >
        Active
      </button>
      <button
        class="btn btn-ghost btn-xs"
        phx-click="set_sender_state"
        phx-value-id={@adapter_id}
        phx-value-state="probing"
      >
        Probe
      </button>
      <button
        class="btn btn-ghost btn-xs"
        phx-click="set_sender_state"
        phx-value-id={@adapter_id}
        phx-value-state="resting"
      >
        Rest
      </button>
    </div>
    """
  end

  defp outcome_label(:ghost), do: "Ghost"
  defp outcome_label(:reply_positive), do: "Reply"
  defp outcome_label(:reply_ooo), do: "Out Of Office"
  defp outcome_label(:hard_bounce), do: "Hard bounce"
  defp outcome_label(:soft_bounce), do: "Soft bounce"
  defp outcome_label(:unsubscribe), do: "Unsubscribe"
  defp outcome_label(:ramp_cap), do: "Ramp cap"
  defp outcome_label(:rest_pinned_sender), do: "Rebind"
  defp outcome_label(_outcome), do: "Outcome"

  defp outcome_description(:ghost),
    do: "No reply or failure. The prospect receives all three touches."

  defp outcome_description(:reply_positive),
    do: "A positive reply is ingested after the first send and the enrollment pauses."

  defp outcome_description(:reply_ooo),
    do: "An out-of-office reply is ingested and future sends are rescheduled."

  defp outcome_description(:hard_bounce),
    do: "A permanent bounce is recorded and the recipient is suppressed."

  defp outcome_description(:soft_bounce),
    do: "A temporary bounce is recorded without suppressing the recipient."

  defp outcome_description(:unsubscribe),
    do: "The prospect unsubscribes and DripDrop records an email suppression."

  defp outcome_description(:ramp_cap),
    do: "The pinned sender hits its daily ramp cap, so the next send is deferred."

  defp outcome_description(:rest_pinned_sender),
    do: "The pinned sender rests, then the pool rebinds the prospect to another sender."

  defp outcome_description(_outcome), do: "Demo outcome"

  defp outcome_icon(:reply_positive), do: "hero-envelope"
  defp outcome_icon(:reply_ooo), do: "hero-calendar-days"
  defp outcome_icon(:hard_bounce), do: "hero-x-mark"
  defp outcome_icon(:soft_bounce), do: "hero-arrow-path"
  defp outcome_icon(:unsubscribe), do: "hero-no-symbol"
  defp outcome_icon(:ramp_cap), do: "hero-chart-bar"
  defp outcome_icon(:rest_pinned_sender), do: "hero-pause"
  defp outcome_icon(_outcome), do: "hero-eye-slash"

  defp outcome_badge_class(:reply_positive), do: "badge-success"
  defp outcome_badge_class(:hard_bounce), do: "badge-error"
  defp outcome_badge_class(:soft_bounce), do: "badge-warning"
  defp outcome_badge_class(:unsubscribe), do: "badge-neutral"
  defp outcome_badge_class(:ramp_cap), do: "badge-warning"
  defp outcome_badge_class(:rest_pinned_sender), do: "badge-info"
  defp outcome_badge_class(_outcome), do: "badge-ghost"

  defp provider_label(nil), do: "unknown"
  defp provider_label("ms365"), do: "Microsoft 365"
  defp provider_label("gmail"), do: "Gmail"
  defp provider_label("smtp"), do: "SMTP"
  defp provider_label("local"), do: "Sandbox"
  defp provider_label(provider), do: provider |> to_string() |> String.replace("_", " ")

  defp health_label(_state, %DateTime{}), do: "paused"
  defp health_label(nil, _paused_until), do: "active"
  defp health_label(state, _paused_until), do: to_string(state)

  defp health_class(:resting, _paused_until), do: "badge-warning"
  defp health_class(:probing, _paused_until), do: "badge-info"
  defp health_class(:ramping, _paused_until), do: "badge-accent"
  defp health_class(_state, %DateTime{}), do: "badge-warning"
  defp health_class(_state, _paused_until), do: "badge-success"

  defp capacity_pct(_sent, nil), do: 8
  defp capacity_pct(sent, cap) when cap > 0, do: min(100, round(sent / cap * 100))
  defp capacity_pct(_sent, _cap), do: 0

  defp min_gap_label(nil, nil, _now), do: "none"
  defp min_gap_label(_last_sent_at, nil, _now), do: "none"
  defp min_gap_label(nil, min_gap_seconds, _now), do: "#{min_gap_seconds}s gap"

  defp min_gap_label(%DateTime{} = last_sent_at, min_gap_seconds, %DateTime{} = now) do
    ready_at = DateTime.add(last_sent_at, min_gap_seconds, :second)
    remaining = DateTime.diff(ready_at, now, :second)

    if remaining > 0, do: "wait #{remaining}s", else: "ready"
  end

  defp min_gap_label(_last_sent_at, min_gap_seconds, _now), do: "#{min_gap_seconds}s gap"

  defp defer_label(%{"reason" => "ramp_cap", "sent_count" => sent, "cap" => cap}) do
    "deferred - ramp cap #{sent}/#{cap}"
  end

  defp defer_label(%{"reason" => "adapter_resting"}), do: "deferred - adapter resting"
  defp defer_label(%{"reason" => "min_gap"}), do: "deferred - min gap"
  defp defer_label(%{"reason" => reason}), do: "deferred - #{reason}"
  defp defer_label(_defer), do: "deferred"
end
