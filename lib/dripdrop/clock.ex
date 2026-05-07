defmodule DripDrop.Clock do
  @moduledoc """
  Centralized UTC clock helpers.

  Production code uses these instead of `DateTime.utc_now/1` directly so the
  second-precision policy and any future test-time clock freezing live in
  one place. The clock is swappable via `config :dripdrop, :clock, MyClock`
  where `MyClock` implements the `c:now/0` callback — useful for freezing
  time in flaky timezone or DST tests.

  All helpers truncate to the second by design. Sub-second precision is not
  used in DripDrop schemas and would only invite drift between code paths.
  """

  @callback now() :: DateTime.t()

  @doc """
  Returns the current UTC time truncated to the second.
  """
  @spec now() :: DateTime.t()
  def now, do: clock().now()

  @doc """
  Returns `now() + seconds`. Pass a negative value for a past timestamp.

  Replaces the recurring `DateTime.utc_now(:second) |> DateTime.add(N, :second)`
  pattern.
  """
  @spec seconds_from_now(integer()) :: DateTime.t()
  def seconds_from_now(seconds), do: DateTime.add(now(), seconds, :second)

  @doc """
  Returns `datetime + seconds` truncated to the second.
  """
  @spec shift(DateTime.t(), integer()) :: DateTime.t()
  def shift(%DateTime{} = datetime, seconds), do: DateTime.add(datetime, seconds, :second)

  defp clock, do: Application.get_env(:dripdrop, :clock) || __MODULE__.System
end

defmodule DripDrop.Clock.System do
  @moduledoc false

  @behaviour DripDrop.Clock

  @impl DripDrop.Clock
  def now, do: DateTime.utc_now(:second)
end
