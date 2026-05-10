defmodule DripdropDemoWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use DripdropDemoWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates("layouts/*")

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")
  attr(:current_path, :string, default: "/", doc: "the current request path")

  attr(:current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"
  )

  slot(:inner_block, required: true)

  def app(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-100 text-base-content">
      <header class="sticky top-0 z-40 border-b border-cyan-900/10 bg-base-100/90 px-4 shadow-sm shadow-cyan-950/5 backdrop-blur-xl sm:px-6 lg:px-8">
        <nav class="mx-auto flex max-w-7xl items-center justify-between gap-4 py-3">
          <a href="/" class="flex min-w-0 items-center gap-3">
            <span class="grid size-11 shrink-0 place-items-center rounded-2xl bg-primary text-primary-content shadow-lg shadow-cyan-600/20">
              <.droplet_logo class="size-7" />
            </span>
            <span class="min-w-0">
              <span class="font-display block text-base font-black tracking-normal">DripDrop</span>
              <span class="block truncate text-xs font-medium text-base-content/50">
                Sequential messaging for Elixir
              </span>
            </span>
          </a>

          <div class="hidden items-center gap-1 md:flex">
            <a
              href="/"
              class={nav_link_class(@current_path, "/")}
              aria-current={nav_current(@current_path, "/")}
            >
              Overview
            </a>
            <a
              href="/scenarios/onboarding"
              class={nav_link_class(@current_path, "/scenarios/onboarding")}
              aria-current={nav_current(@current_path, "/scenarios/onboarding")}
            >
              User Onboarding
            </a>
            <a
              href="/scenarios/lead-nurture"
              class={nav_link_class(@current_path, "/scenarios/lead-nurture")}
              aria-current={nav_current(@current_path, "/scenarios/lead-nurture")}
            >
              Lead Nurture
            </a>
            <a
              href="/scenarios/outbound"
              class={nav_link_class(@current_path, "/scenarios/outbound")}
              aria-current={nav_current(@current_path, "/scenarios/outbound")}
            >
              Outbound Campaigns
            </a>
          </div>

          <div class="flex shrink-0 items-center gap-2">
            <a
              href="https://github.com/agoodway/dripdrop"
              target="_blank"
              rel="noopener"
              aria-label="View DripDrop on GitHub"
              class="btn btn-ghost btn-sm btn-square text-base-content/70 hover:text-base-content"
            >
              <svg viewBox="0 0 24 24" aria-hidden="true" class="size-5 fill-current">
                <path d="M12 .5C5.65.5.5 5.65.5 12c0 5.09 3.29 9.39 7.86 10.91.58.1.79-.25.79-.56v-2.14c-3.2.7-3.88-1.36-3.88-1.36-.52-1.33-1.28-1.68-1.28-1.68-1.05-.72.08-.71.08-.71 1.16.08 1.77 1.19 1.77 1.19 1.03 1.76 2.7 1.25 3.36.96.1-.75.4-1.25.73-1.54-2.55-.29-5.23-1.28-5.23-5.68 0-1.25.45-2.28 1.18-3.08-.12-.29-.51-1.46.11-3.04 0 0 .96-.31 3.16 1.18.92-.26 1.9-.38 2.87-.39.97 0 1.95.13 2.87.39 2.19-1.49 3.15-1.18 3.15-1.18.63 1.58.23 2.75.11 3.04.74.8 1.18 1.83 1.18 3.08 0 4.42-2.69 5.39-5.25 5.67.42.36.78 1.06.78 2.14v3.17c0 .31.21.67.79.56A11.51 11.51 0 0 0 23.5 12C23.5 5.65 18.35.5 12 .5Z" />
              </svg>
            </a>
            <.theme_toggle />
          </div>
        </nav>
      </header>

      <main id="main" class="relative overflow-hidden px-4 py-8 sm:px-6 lg:px-8">
        <div class="pointer-events-none absolute inset-x-0 top-0 -z-10 h-72 bg-[linear-gradient(180deg,oklch(91%_0.08_220/.9),transparent)]" />
        <div class="pointer-events-none absolute inset-x-0 top-0 -z-10 h-48 opacity-50 dripdrop-wave" />
        <div class="mx-auto max-w-7xl">
          {render_slot(@inner_block)}
        </div>
      </main>

      <footer class="border-t border-cyan-900/10 px-4 py-6 sm:px-6 lg:px-8">
        <div class="mx-auto flex max-w-7xl items-center justify-center text-sm text-base-content/55">
          <span>
            A project by
            <a
              href="https://goodway.dev?ref=dripdrop"
              target="_blank"
              rel="noopener"
              class="font-semibold text-primary hover:underline"
            >
              Goodway
            </a>
            — we build software that drives results.
          </span>
        </div>
      </footer>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  defp nav_link_class(current_path, path) do
    [
      "btn btn-sm",
      current_path == path &&
        "btn-primary shadow-sm shadow-cyan-900/10",
      current_path != path &&
        "btn-ghost text-base-content/70 hover:bg-info/10 hover:text-base-content"
    ]
  end

  defp nav_current(path, path), do: "page"
  defp nav_current(_current_path, _path), do: nil

  attr(:class, :string, default: nil)

  def droplet_logo(assigns) do
    ~H"""
    <svg viewBox="0 0 64 64" fill="none" aria-hidden="true" class={@class}>
      <path
        d="M32 5C24.2 16.2 14 27.7 14 39.1C14 51 22.2 59 32 59s18-8 18-19.9C50 27.7 39.8 16.2 32 5Z"
        fill="currentColor"
      />
      <path
        d="M24.1 39.7c.3 5.9 4.2 9.8 9.9 10.1"
        stroke="oklch(100% 0 0 / .76)"
        stroke-width="5"
        stroke-linecap="round"
      />
      <path
        d="M35.5 19.5c4.1 5.4 7.4 11.2 7.4 17.3"
        stroke="oklch(100% 0 0 / .35)"
        stroke-width="4"
        stroke-linecap="round"
      />
    </svg>
    """
  end

  attr(:name, :string, required: true)
  attr(:description, :string, required: true)
  attr(:href, :string, default: nil)
  attr(:icon, :string, required: true)

  def demo_tile(assigns) do
    ~H"""
    <.link
      :if={@href}
      href={@href}
      class={[
        "group block rounded-lg border border-base-300/70 bg-base-100 p-5 shadow-sm transition",
        "hover:-translate-y-0.5 hover:border-primary/40 hover:shadow-xl hover:shadow-cyan-900/10"
      ]}
    >
      <.demo_tile_content name={@name} description={@description} icon={@icon} clickable? />
    </.link>
    <div
      :if={!@href}
      class="block rounded-lg border border-base-300/70 bg-base-100 p-5 opacity-70 shadow-sm"
    >
      <.demo_tile_content name={@name} description={@description} icon={@icon} />
    </div>
    """
  end

  attr(:name, :string, required: true)
  attr(:description, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:clickable?, :boolean, default: false)

  def demo_tile_content(assigns) do
    ~H"""
    <div class="flex items-center gap-4">
      <div class="min-w-0 flex-1">
        <span class="grid size-11 place-items-center rounded-lg bg-info/10 text-info">
          <.icon name={@icon} class="size-5" />
        </span>
        <div class="mt-5">
          <div class="text-sm font-bold text-base-content">{@name}</div>
          <p class="mt-2 text-sm leading-6 text-base-content/60">{@description}</p>
        </div>
      </div>
      <span
        :if={@clickable?}
        class="grid size-9 shrink-0 place-items-center rounded-full text-base-content/35 transition group-hover:translate-x-1 group-hover:bg-primary/10 group-hover:text-primary"
      >
        <.icon name="hero-arrow-right" class="size-5" />
      </span>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")
  attr(:id, :string, default: "flash-group", doc: "the optional id of flash container")

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative flex flex-row items-center rounded-full border border-base-300 bg-base-200 p-0.5 shadow-inner">
      <div class="absolute h-[calc(100%-4px)] w-1/3 rounded-full bg-base-100 shadow-sm left-0.5 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-[calc(66.666%-2px)] transition-[left]" />

      <button
        class="relative flex cursor-pointer p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="Use system theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="relative flex cursor-pointer p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Use light theme"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="relative flex cursor-pointer p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Use dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
