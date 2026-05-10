defmodule DripdropDemo.ScenarioCatalog do
  @moduledoc """
  Single source of truth for demo scenario metadata: name, icon, route, and the
  description used on both the home page tile and the scenario page subtitle.

  Centralized here so the home tile and the scenario page subtitle never drift
  out of sync.
  """

  @type t :: %{
          key: atom(),
          name: String.t(),
          icon: String.t(),
          route: String.t(),
          description: String.t()
        }

  @scenarios [
    %{
      key: :user_onboarding,
      name: "User Onboarding",
      icon: "hero-rocket-launch",
      route: "/scenarios/onboarding",
      description:
        "Welcome a new user with email, send a Telegram team alert, an in-app nudge, an HTTP setup check that gates the next step, then an SMS confirmation."
    },
    %{
      key: :lead_nurture,
      name: "Lead Nurture",
      icon: "hero-map",
      route: "/scenarios/lead-nurture",
      description:
        "Verify a lead's email with an Elixir hook, score it through an HTTP hook, branch on the result, then alert sales or push to nurture and update CRM."
    },
    %{
      key: :outbound_campaigns,
      name: "Outbound Campaigns",
      icon: "hero-paper-airplane",
      route: "/scenarios/outbound",
      description:
        "Drip a prospect campaign through a sender pool with mailbox ramping, daily caps, threaded follow-ups, and auto-pause on reply."
    }
  ]

  @doc "Returns all demo scenarios in tile order."
  @spec list() :: [t()]
  def list, do: @scenarios

  @doc "Returns the scenario by key, raising if not found."
  @spec fetch!(atom()) :: t()
  def fetch!(key) do
    Enum.find(@scenarios, &(&1.key == key)) ||
      raise ArgumentError, "unknown scenario: #{inspect(key)}"
  end
end
