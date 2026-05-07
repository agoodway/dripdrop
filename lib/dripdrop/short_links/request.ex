defmodule DripDrop.ShortLinks.Request do
  @moduledoc """
  Provider-neutral request for creating a short link.
  """

  @enforce_keys [:original_url, :destination_url, :idempotency_key]
  defstruct [
    :original_url,
    :destination_url,
    :idempotency_key,
    :tenant_key,
    :channel,
    :sequence_key,
    :step_key,
    :domain,
    :key,
    :prefix,
    metadata: %{},
    utm: %{}
  ]

  @type t :: %__MODULE__{
          original_url: binary(),
          destination_url: binary(),
          idempotency_key: binary(),
          tenant_key: binary() | nil,
          channel: binary() | atom() | nil,
          sequence_key: binary() | nil,
          step_key: binary() | nil,
          domain: binary() | nil,
          key: binary() | nil,
          prefix: binary() | nil,
          metadata: map(),
          utm: map()
        }
end
