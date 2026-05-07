defmodule DripDrop.ShortLinks.Result do
  @moduledoc """
  Provider-neutral result from creating a short link.
  """

  @enforce_keys [:short_url]
  defstruct [:short_url, :provider_id, response: %{}]

  @type t :: %__MODULE__{
          short_url: binary(),
          provider_id: binary() | nil,
          response: map()
        }
end
