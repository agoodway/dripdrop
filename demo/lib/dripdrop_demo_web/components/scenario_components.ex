defmodule DripdropDemoWeb.ScenarioComponents do
  @moduledoc """
  Shared UI components for DripDrop demo scenarios.
  """

  use DripdropDemoWeb, :html

  alias Makeup.Lexers.ElixirLexer

  @json_token_pattern ~r/"(?:\\.|[^"\\])*"\s*:|"(?:\\.|[^"\\])*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|\b(?:true|false|null)\b/

  attr(:title, :string, required: true)
  attr(:subtitle, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:status, :string, default: nil)
  slot(:inner_block, required: true)

  def scenario_panel(assigns) do
    ~H"""
    <section class="rounded-lg border border-cyan-900/10 bg-base-100/90 p-5 shadow-xl shadow-cyan-950/5 backdrop-blur">
      <div class="flex items-center justify-between border-b border-base-300/70 pb-4">
        <div class="flex items-center gap-3">
          <span class="grid size-10 place-items-center rounded-lg bg-info/10 text-info">
            <.icon name={@icon} class="size-5" />
          </span>
          <div>
            <h2 class="text-sm font-bold">{@title}</h2>
            <p class="text-xs text-base-content/50">{@subtitle}</p>
          </div>
        </div>
        <span :if={@status} class="badge badge-info badge-soft">{@status}</span>
      </div>
      <div class="mt-5">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  attr(:title, :string, required: true)
  attr(:subtitle, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:status, :string, default: nil)
  attr(:logs_open?, :boolean, required: true)
  attr(:events, :list, required: true)

  attr(:logs_empty, :string,
    default: "# Live DripDrop events will stream here after dispatch starts."
  )

  slot(:inner_block, required: true)

  def sequence_messages_flipper(assigns) do
    ~H"""
    <section class="flex h-full min-h-0 flex-col rounded-lg border border-cyan-900/10 bg-base-100/90 p-5 shadow-xl shadow-cyan-950/5 backdrop-blur">
      <div class="shrink-0 flex items-center justify-between gap-4 border-b border-base-300/70 pb-4">
        <div class="flex items-center gap-3">
          <span class="grid size-10 place-items-center rounded-lg bg-info/10 text-info">
            <.icon name={@icon} class="size-5" />
          </span>
          <div>
            <h2 class="text-sm font-bold">{@title}</h2>
            <p class="text-xs text-base-content/50">{@subtitle}</p>
          </div>
        </div>
        <div class="flex shrink-0 items-center gap-2">
          <span :if={@status} class="badge badge-info badge-soft">{@status}</span>
          <button
            type="button"
            class={["btn btn-xs", if(@logs_open?, do: "btn-info", else: "btn-outline")]}
            phx-click="toggle_sequence_logs"
          >
            <.icon name="hero-command-line" class="size-4" />
            {if @logs_open?, do: "View Sequence messages", else: "View Sequence logs"}
          </button>
        </div>
      </div>

      <div class="scenario-flip relative mt-5 min-h-[28rem] flex-1">
        <div class={[
          "scenario-flip-card relative grid h-full min-h-[28rem]",
          @logs_open? && "is-flipped"
        ]}>
          <div
            aria-hidden={@logs_open?}
            class={[
              "scenario-flip-face col-start-1 row-start-1 h-full min-h-0",
              if(@logs_open?, do: "pointer-events-none", else: "pointer-events-auto")
            ]}
          >
            {render_slot(@inner_block)}
          </div>

          <div
            aria-hidden={!@logs_open?}
            class={[
              "scenario-flip-face-back absolute inset-0 h-full min-h-0",
              if(@logs_open?, do: "pointer-events-auto", else: "pointer-events-none")
            ]}
          >
            <.runtime_logs
              events={@events}
              empty={@logs_empty}
              label="Sequence logs"
              compact?={true}
            />
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr(:title, :string, required: true)
  attr(:subtitle, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:steps, :list, required: true)
  attr(:selected_step_key, :string, default: nil)
  attr(:code_open?, :boolean, required: true)
  attr(:code_title, :string, required: true)
  attr(:code, :string, required: true)

  def sequence_flipper(assigns) do
    ~H"""
    <section class="flex h-full min-h-0 flex-col rounded-lg border border-cyan-900/10 bg-base-100/90 p-5 shadow-xl shadow-cyan-950/5 backdrop-blur">
      <div class="shrink-0 flex items-center justify-between gap-4 border-b border-base-300/70 pb-4">
        <div class="flex items-center gap-3">
          <span class="grid size-10 place-items-center rounded-lg bg-info/10 text-info">
            <.icon name={@icon} class="size-5" />
          </span>
          <div>
            <h2 class="text-sm font-bold">{@title}</h2>
            <p class="text-xs text-base-content/50">{@subtitle}</p>
          </div>
        </div>
        <button
          type="button"
          class={["btn btn-xs", if(@code_open?, do: "btn-info", else: "btn-outline")]}
          phx-click="toggle_api_mirror"
        >
          <.icon name="hero-code-bracket-square" class="size-4" />
          {if @code_open?, do: "View Sequence steps", else: "View Sequence code"}
        </button>
      </div>

      <div class="scenario-flip relative mt-5 min-h-[28rem] flex-1">
        <div class={[
          "scenario-flip-card relative grid h-full min-h-[28rem]",
          @code_open? && "is-flipped"
        ]}>
          <div
            aria-hidden={@code_open?}
            class={[
              "scenario-flip-face sequence-step-list col-start-1 row-start-1 h-full min-h-0 space-y-3",
              if(@code_open?, do: "pointer-events-none", else: "pointer-events-auto")
            ]}
          >
            <button
              :for={step <- @steps}
              type="button"
              phx-click="select_step"
              phx-value-key={step.key}
              class={[
                "step-rise-in w-full rounded-lg border p-4 text-left transition-all hover:-translate-y-0.5 hover:border-info/60 hover:shadow-lg focus:outline-none focus-visible:ring-2 focus-visible:ring-info/70",
                step_card_class(step),
                selected_step_class(@selected_step_key, step.key)
              ]}
            >
              <div class="flex items-start gap-4">
                <span class={[
                  "grid size-10 shrink-0 place-items-center rounded-lg",
                  step_icon_class(step)
                ]}>
                  <.step_icon name={step.icon} class="size-5" />
                </span>
                <div class="min-w-0 flex-1">
                  <div class="flex items-center justify-between gap-3">
                    <div>
                      <div class="text-sm font-bold text-base-content">{step.name}</div>
                      <div class="text-xs text-base-content/50">{step.key}</div>
                    </div>
                    <span class="badge badge-sm">{step.state}</span>
                  </div>
                  <div class="mt-3 grid gap-2 text-xs text-base-content/55 sm:grid-cols-3">
                    <div>
                      <span class="font-semibold text-base-content/40">Channel</span>
                      <div>{step.channel}</div>
                    </div>
                    <div>
                      <span class="font-semibold text-base-content/40">Timing</span>
                      <div>{step.timing}</div>
                    </div>
                    <div>
                      <span class="font-semibold text-base-content/40">Executed</span>
                      <div>{format_step_dt(step)}</div>
                    </div>
                  </div>
                </div>
              </div>
            </button>
          </div>

          <div
            aria-hidden={!@code_open?}
            class={[
              "scenario-flip-face-back absolute inset-0 flex h-full min-h-0 flex-col overflow-hidden rounded-lg border border-info/25 bg-slate-950 shadow-xl shadow-cyan-950/10",
              if(@code_open?, do: "pointer-events-auto", else: "pointer-events-none")
            ]}
          >
            <div class="shrink-0 flex items-center justify-between border-b border-white/10 bg-slate-900 px-4 py-3">
              <div class="flex items-center gap-2">
                <span class="size-3 rounded-full bg-red-400"></span>
                <span class="size-3 rounded-full bg-amber-300"></span>
                <span class="size-3 rounded-full bg-emerald-400"></span>
              </div>
              <div class="flex items-center gap-3 font-mono text-xs">
                <span class="rounded-full border border-cyan-400/20 bg-cyan-400/10 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-widest text-cyan-300">
                  Sequence code
                </span>
              </div>
              <div class="w-14"></div>
            </div>
            <div class="min-h-0 flex-1 overflow-auto p-4 pb-10 text-xs leading-6 text-cyan-50">
              {highlight_elixir(@code)}
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr(:webhook, :map, required: true)
  attr(:step_key, :string, required: true)
  attr(:label, :string, default: "Webhook")
  attr(:endpoint, :string, default: "POST /crm-update")
  attr(:selected?, :boolean, default: false)
  attr(:rest, :global)

  def webhook_card(assigns) do
    ~H"""
    <div
      {@rest}
      class={[
        "artifact-slide-in overflow-hidden rounded-lg border border-slate-200 bg-slate-50 shadow-xl shadow-slate-950/5 transition-all hover:-translate-y-0.5 hover:border-info/60 dark:border-slate-700 dark:bg-slate-900",
        @selected? &&
          "border-info/70 ring-2 ring-info/60 ring-offset-2 ring-offset-base-100 shadow-2xl shadow-info/15"
      ]}
    >
      <div class="flex items-center justify-between border-b border-slate-200 bg-white px-4 py-3 dark:border-slate-700 dark:bg-slate-800">
        <div>
          <div class="text-xs font-bold uppercase text-slate-500 dark:text-slate-300">
            {@label}
          </div>
          <div class="mt-0.5 text-[11px] font-semibold text-slate-500 dark:text-slate-300">
            {@step_key}
          </div>
        </div>
        <span class="badge badge-sm">{@endpoint}</span>
      </div>
      <div class="overflow-x-auto bg-slate-800 p-4 text-xs leading-6 text-slate-100 dark:bg-slate-950 dark:text-cyan-50">
        {highlight_json(webhook_preview(@webhook))}
      </div>
    </div>
    """
  end

  attr(:step_key, :string, required: true)
  attr(:label, :string, required: true)
  attr(:title, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:icon_class, :string, default: "bg-info text-info-content")
  attr(:badge, :string, default: nil)
  attr(:selected?, :boolean, default: false)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def decision_card(assigns) do
    ~H"""
    <div
      {@rest}
      class={[
        "artifact-slide-in rounded-lg border border-info/20 bg-info/5 p-4 shadow-xl shadow-cyan-950/10 transition-all hover:-translate-y-0.5 hover:border-info/60",
        @selected? &&
          "border-info/70 ring-2 ring-info/60 ring-offset-2 ring-offset-base-100 shadow-2xl shadow-info/15"
      ]}
    >
      <div class="mb-3 flex items-center justify-between gap-3">
        <div>
          <div class="text-xs font-bold uppercase text-info">{@label}</div>
          <div class="mt-0.5 text-[11px] font-semibold text-base-content/45">{@step_key}</div>
        </div>
        <span :if={@badge} class="badge badge-sm">{@badge}</span>
      </div>

      <div class="flex gap-3">
        <span class={["grid size-9 shrink-0 place-items-center rounded-lg", @icon_class]}>
          <.step_icon name={@icon} class="size-5" />
        </span>
        <div class="min-w-0 flex-1">
          <div class="font-bold text-base-content">{@title}</div>
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  attr(:events, :list, required: true)
  attr(:empty, :string, default: "# Live DripDrop events will stream here after dispatch starts.")
  attr(:label, :string, default: "Streaming DripDrop logs")
  attr(:compact?, :boolean, default: false)
  attr(:id, :string, default: "sequence-logs")

  def runtime_logs(assigns) do
    ~H"""
    <section class={[
      "overflow-hidden rounded-lg border border-slate-800 bg-slate-950 shadow-2xl shadow-cyan-950/20",
      @compact? && "flex h-full min-h-0 flex-col shadow-lg"
    ]}>
      <div class="shrink-0 flex items-center justify-between border-b border-white/10 bg-slate-900 px-4 py-3">
        <div class="flex items-center gap-2">
          <span class="size-3 rounded-full bg-red-400"></span>
          <span class="size-3 rounded-full bg-amber-300"></span>
          <span class="size-3 rounded-full bg-emerald-400"></span>
        </div>
        <div class="flex items-center gap-3 font-mono text-xs">
          <span class="rounded-full border border-cyan-400/20 bg-cyan-400/10 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-widest text-cyan-300">
            {@label}
          </span>
        </div>
        <div class="w-14"></div>
      </div>
      <div
        id={@id}
        phx-hook="AutoScrollLog"
        data-event-count={length(@events)}
        class={[
          "overflow-auto p-4 font-mono text-xs leading-6 text-cyan-100",
          if(@compact?, do: "min-h-0 flex-1", else: "max-h-96")
        ]}
        aria-live="polite"
      >
        <div :if={@events == []} class="text-slate-500">{@empty}</div>
        <div :for={event <- @events} class="mb-2">
          <div class="text-emerald-300"># DripDrop telemetry event</div>
          <div class="text-cyan-100">
            {highlight_elixir(event_terminal_line(event))}
          </div>
          <div :if={event_runtime_mirror(event)} class="text-sky-300">
            # related runtime state
          </div>
          <div :if={event_runtime_mirror(event)} class="text-slate-200">
            {highlight_elixir(event_runtime_mirror(event))}
          </div>
        </div>
      </div>
    </section>
    """
  end

  def highlight_elixir(code) do
    code
    |> Makeup.highlight(lexer: ElixirLexer)
    |> Phoenix.HTML.raw()
  rescue
    _error ->
      code
      |> Phoenix.HTML.html_escape()
  end

  attr(:name, :string, required: true)
  attr(:class, :string, default: "size-5")

  def step_icon(%{name: "demo-elixir-drop"} = assigns) do
    ~H"""
    <svg
      class={@class}
      viewBox="0 0 128 128"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      aria-hidden="true"
    >
      <path
        fill-rule="evenodd"
        clip-rule="evenodd"
        d="M64.4.5C36.7 13.9 1.9 83.4 30.9 113.9c26.8 33.5 85.4 1.3 68.4-40.5-21.5-36-35-37.9-34.9-72.9z"
        class="fill-current opacity-30"
      />
      <path
        fill-rule="evenodd"
        clip-rule="evenodd"
        d="M64.4.2C36.8 13.6 1.9 82.9 31 113.5c10.7 12.4 28 16.5 37.7 9.1 26.4-18.8 7.4-53.1 10.4-78.5C68.1 33.9 64.2 11.3 64.4.2z"
        class="fill-current opacity-85"
      />
      <path
        fill-rule="evenodd"
        clip-rule="evenodd"
        d="M56.7 4.3c-22.3 15.9-28.2 75-24.1 94.2 8.2 48.1 75.2 28.3 69.6-16.5-6-29.2-48.8-39.2-45.5-77.7z"
        class="fill-current opacity-70"
      />
      <path
        fill-rule="evenodd"
        clip-rule="evenodd"
        d="M78.8 49.8c10.4 13.4 12.7 22.6 6.8 27.9-27.7 19.4-61.3 7.4-54-37.3C22.1 63 4.5 96.8 43.3 101.6c20.8 3.6 54 2 58.9-16.1-.2-15.9-10.8-22.9-23.4-35.7z"
        class="fill-purple-950 opacity-35 dark:fill-white dark:opacity-20"
      />
      <path
        fill-rule="evenodd"
        clip-rule="evenodd"
        d="M38.1 36.4c-2.9 21.2 35.1 77.9 58.3 71-17.7 35.6-56.9-21.2-64-41.7 1.5-11 2.2-16.4 5.7-29.3z"
        class="fill-purple-950 opacity-45 dark:fill-white dark:opacity-25"
      />
      <path
        fill-rule="evenodd"
        clip-rule="evenodd"
        d="M60.4 49.7c.8 7.9 3.9 20.5 0 28.8S38.7 102 43.6 115.3c11.4 24.8 37.1-4.4 36.9-19 1.1-11.8-6.6-38.7-1.8-52.5L76.5 41l-13.6-4c-2.2 3.2-3 7.5-2.5 12.7z"
        class="fill-white opacity-25"
      />
      <path
        fill-rule="evenodd"
        clip-rule="evenodd"
        d="M65.3 10.8C36 27.4 48 53.4 49.3 81.6l19.1-55.4c-1.4-5.7-2.3-9.5-3.1-15.4z"
        class="fill-purple-950 opacity-35 dark:fill-white dark:opacity-20"
      />
      <path
        fill-rule="evenodd"
        clip-rule="evenodd"
        d="M68.3 26.1c-14.8 11.7-14.1 31.3-18.6 54 8.1-21.3 4.1-38.2 18.6-54z"
        class="fill-purple-950 opacity-40 dark:fill-white dark:opacity-25"
      />
      <path
        fill-rule="evenodd"
        clip-rule="evenodd"
        d="M45.8 119.7c8 1.1 12.1 2.2 12.5 3 .3 4.2-11.1 1.2-12.5-3z"
        class="fill-white opacity-80"
      />
      <path
        fill-rule="evenodd"
        clip-rule="evenodd"
        d="M49.8 10.8c-6.9 7.7-14.4 21.8-18.2 29.7-1 6.5-.5 15.7.6 23.5.9-18.2 7.5-39.2 17.6-53.2z"
        class="fill-white opacity-45"
      />
    </svg>
    """
  end

  def step_icon(assigns) do
    ~H"""
    <.icon name={@name} class={@class} />
    """
  end

  def highlight_json(json) do
    @json_token_pattern
    |> Regex.replace(json, fn token -> json_token(token) end)
    |> then(&~s(<pre class="json-code whitespace-pre-wrap"><code>#{&1}</code></pre>))
    |> Phoenix.HTML.raw()
  end

  def execution_state(nil), do: "waiting"
  def execution_state(%{state: state}), do: to_string(state)

  def execution_phase(nil), do: :pending

  def execution_phase(%{state: state}) do
    case to_string(state) do
      s when s in ["sent", "delivered", "completed"] -> :complete
      s when s in ["failed", "skipped", "suppressed"] -> :issue
      _other -> :active
    end
  end

  def webhook_preview(%{body: body} = webhook) do
    %{
      "method" => Map.get(webhook, :method, "POST"),
      "path" => Map.get(webhook, :path, "/crm-update"),
      "headers" => Map.get(webhook, :headers, %{}),
      "body" => decode_json_body(body)
    }
    |> Jason.encode!(pretty: true)
  end

  def webhook_preview(_webhook), do: "{}"

  defp json_token(token) do
    escaped = html_escape_to_string(token)
    key_token = String.trim_trailing(token)

    cond do
      String.ends_with?(key_token, ":") ->
        key =
          key_token
          |> String.trim_trailing(":")
          |> String.trim_trailing()
          |> html_escape_to_string()

        ~s(<span class="json-key">#{key}</span>:)

      String.starts_with?(token, "\"") ->
        ~s(<span class="json-string">#{escaped}</span>)

      token in ["true", "false", "null"] ->
        ~s(<span class="json-literal">#{escaped}</span>)

      true ->
        ~s(<span class="json-number">#{escaped}</span>)
    end
  end

  defp html_escape_to_string(value) do
    value
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp step_card_class(%{phase: :active}),
    do: "border-primary/70 bg-primary/10 shadow-lg shadow-cyan-900/10"

  defp step_card_class(%{phase: :complete}), do: "border-success/50 bg-success/10"
  defp step_card_class(%{phase: :issue}), do: "border-error/60 bg-error/10"
  defp step_card_class(_step), do: "border-base-300/70 bg-base-100/70"

  defp step_icon_class(%{phase: :active}), do: "bg-primary text-primary-content"
  defp step_icon_class(%{phase: :complete}), do: "bg-success text-success-content"
  defp step_icon_class(%{phase: :issue}), do: "bg-error text-error-content"
  defp step_icon_class(%{icon_class: icon_class}), do: icon_class
  defp step_icon_class(_step), do: "bg-base-200 text-base-content/50"

  defp selected_step_class(key, key) do
    "border-info/70 ring-2 ring-info/60 ring-offset-2 ring-offset-base-100 shadow-2xl shadow-info/15"
  end

  defp selected_step_class(_selected_step_key, _key), do: ""

  defp format_step_dt(%{executed_at: %DateTime{} = datetime}), do: format_dt(datetime)

  defp format_step_dt(%{execution: %{executed_at: %DateTime{} = datetime}}),
    do: format_dt(datetime)

  defp format_step_dt(_step), do: "-"

  defp format_dt(datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%H:%M:%S")
  end

  defp event_terminal_line(event) do
    inspect(
      %{event: event.event, measurements: event.measurements, metadata: event.metadata},
      pretty: true,
      limit: :infinity
    )
  end

  defp event_runtime_mirror(%{event: "dripdrop.dispatch.sent", metadata: metadata}) do
    inspect(
      %{
        persisted_as: "DripDrop.MessageEvent",
        event_type: "sent",
        step_key: metadata.step_key,
        channel: metadata.channel,
        provider_message_id: metadata.provider_message_id,
        step_execution_id: metadata.step_execution_id
      },
      pretty: true,
      limit: :infinity
    )
  end

  defp event_runtime_mirror(%{event: "dripdrop.demo.pubsub.received", metadata: metadata}) do
    inspect(
      %{
        delivered_as: "Phoenix.PubSub message",
        step_key: Map.get(metadata, :step_key, "in-app-nudge"),
        event: metadata.event,
        title: Map.get(metadata, :title)
      },
      pretty: true,
      limit: :infinity
    )
  end

  defp event_runtime_mirror(%{event: "dripdrop.demo.webhook.received", metadata: metadata}) do
    inspect(
      %{
        received_as: "CRM webhook event",
        step_key: Map.get(metadata, :step_key, "crm-update-webhook"),
        method: metadata.method,
        path: metadata.path
      },
      pretty: true,
      limit: :infinity
    )
  end

  defp event_runtime_mirror(_event), do: nil

  defp decode_json_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _not_json -> %{"data" => body}
    end
  end

  defp decode_json_body(body) when is_map(body), do: body
  defp decode_json_body(body), do: %{"data" => inspect(body)}
end
