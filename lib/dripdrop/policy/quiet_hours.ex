defmodule DripDrop.Policy.QuietHours do
  @moduledoc """
  Defers dispatch outside recipient-local sending hours.
  """

  alias DripDrop.Repo

  @doc """
  Checks recipient-local quiet hours and returns a defer time when blocked.
  """
  @spec check(map()) :: :ok | {:defer, DateTime.t(), map()} | {:error, map()}
  def check(%{step: step, enrollment: enrollment} = context) do
    with {:enabled, true} <- {:enabled, enabled?(step)},
         {:ok, {start_hour, end_hour}} <- quiet_hours(step),
         timezone <- timezone(context, enrollment),
         {:ok, decision} <- postgres_decision(timezone, start_hour, end_hour) do
      emit_decision(decision, context, timezone, start_hour, end_hour)
    else
      {:enabled, false} -> :ok
      {:error, reason} -> {:error, %{kind: :permanent, reason: reason}}
    end
  end

  def check(_context), do: :ok

  defp emit_decision(%{allowed?: true}, _context, _timezone, _start_hour, _end_hour), do: :ok

  defp emit_decision(
         %{allowed?: false, defer_until: defer_until},
         context,
         timezone,
         start_hour,
         end_hour
       ) do
    :telemetry.execute([:dripdrop, :policy, :quiet_hours], %{count: 1}, %{
      step_execution_id: context.execution.id,
      tenant_key: context.execution.tenant_key,
      channel: context.execution.channel,
      timezone: timezone,
      start_hour: start_hour,
      end_hour: end_hour,
      defer_until: defer_until
    })

    {:defer, defer_until,
     %{reason: "quiet_hours", timezone: timezone, start_hour: start_hour, end_hour: end_hour}}
  end

  defp postgres_decision(timezone, start_hour, end_hour) do
    sql = """
    WITH local_clock AS (
      SELECT
        timezone($1::text, now()) AS local_now,
        extract(hour from timezone($1::text, now()))::int AS local_hour
    ),
    decision AS (
      SELECT
        CASE
          WHEN $2::int < $3::int THEN local_hour >= $2::int AND local_hour < $3::int
          ELSE local_hour >= $2::int OR local_hour < $3::int
        END AS allowed,
        CASE
          WHEN $2::int < $3::int AND local_hour < $2::int THEN date_trunc('day', local_now) + make_interval(hours => $2::int)
          WHEN $2::int < $3::int THEN date_trunc('day', local_now) + interval '1 day' + make_interval(hours => $2::int)
          WHEN local_hour < $2::int AND local_hour >= $3::int THEN date_trunc('day', local_now) + make_interval(hours => $2::int)
          ELSE date_trunc('day', local_now) + interval '1 day' + make_interval(hours => $2::int)
        END AS next_local
      FROM local_clock
    )
    SELECT allowed, timezone($1::text, next_local) AS defer_until
    FROM decision
    """

    case Repo.query(sql, [timezone, start_hour, end_hour]) do
      {:ok, %{rows: [[allowed?, defer_until]]}} ->
        {:ok, %{allowed?: allowed?, defer_until: defer_until}}

      {:error, reason} ->
        {:error, {:quiet_hours_timezone, timezone, reason}}
    end
  end

  defp enabled?(%{config: %{"quiet_hours" => false}}), do: false
  defp enabled?(%{config: %{quiet_hours: false}}), do: false
  defp enabled?(_step), do: true

  defp quiet_hours(%{config: %{"quiet_hours" => config}}) when is_map(config) do
    parse_hours(
      Map.get(config, "start") || Map.get(config, :start),
      Map.get(config, "end") || Map.get(config, :end)
    )
  end

  defp quiet_hours(%{config: %{quiet_hours: config}}) when is_map(config) do
    parse_hours(
      Map.get(config, "start") || Map.get(config, :start),
      Map.get(config, "end") || Map.get(config, :end)
    )
  end

  defp quiet_hours(_step) do
    case Application.get_env(:dripdrop, :quiet_hours_default, {8, 21}) do
      {start_hour, end_hour} -> parse_hours(start_hour, end_hour)
      false -> {:enabled, false}
      nil -> {:enabled, false}
    end
  end

  defp parse_hours(start_hour, end_hour) do
    with {:ok, start_hour} <- parse_hour(start_hour),
         {:ok, end_hour} <- parse_hour(end_hour) do
      {:ok, {start_hour, end_hour}}
    end
  end

  defp parse_hour(hour) when is_integer(hour) and hour in 0..23, do: {:ok, hour}

  defp parse_hour(hour) when is_binary(hour) do
    case Integer.parse(hour) do
      {hour, ""} when hour in 0..23 -> {:ok, hour}
      _invalid -> {:error, {:invalid_quiet_hour, hour}}
    end
  end

  defp parse_hour(hour), do: {:error, {:invalid_quiet_hour, hour}}

  defp timezone(context, enrollment) do
    enrollment_timezone(enrollment) ||
      step_timezone(context.step) ||
      channel_timezone(context.execution.channel) ||
      tenant_timezone(context.sequence) ||
      Application.get_env(:dripdrop, :default_timezone, "Etc/UTC")
  end

  defp enrollment_timezone(%{data: data}) when is_map(data),
    do: Map.get(data, "timezone") || Map.get(data, :timezone)

  defp enrollment_timezone(_enrollment), do: nil

  defp step_timezone(%{config: %{"timezone" => timezone}}), do: timezone
  defp step_timezone(%{config: %{timezone: timezone}}), do: timezone
  defp step_timezone(_step), do: nil

  defp channel_timezone(channel) do
    config = Application.get_env(:dripdrop, :quiet_hours_timezones, [])

    case DripDrop.Helpers.atom_or_string(channel) do
      atom when is_atom(atom) -> Keyword.get(config, atom)
      _binary -> nil
    end
  end

  defp tenant_timezone(%{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "default_timezone") || Map.get(metadata, :default_timezone) ||
      Map.get(metadata, "timezone") || Map.get(metadata, :timezone)
  end

  defp tenant_timezone(_sequence), do: nil
end
