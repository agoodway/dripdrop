defmodule DripDrop.Policy.RateLimit.Backend do
  @moduledoc """
  Behaviour for rate-limit backends used by the messaging policy gate.
  """

  @callback check(map(), map()) ::
              :ok | {:defer, DateTime.t(), map()} | {:error, term()}
end
