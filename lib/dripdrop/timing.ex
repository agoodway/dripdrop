defmodule DripDrop.Timing do
  @moduledoc """
  Embedded timing configuration for sequence steps.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Crontab.CronExpression.Parser
  alias Crontab.Scheduler

  @primary_key false
  @delay_units ~w(minutes hours days weeks)
  @timing_types ~w(immediate delay cron event)
  @weekdays %{
    "sunday" => 0,
    "monday" => 1,
    "tuesday" => 2,
    "wednesday" => 3,
    "thursday" => 4,
    "friday" => 5,
    "saturday" => 6
  }

  embedded_schema do
    field(:type, :string)
    field(:delay_amount, :integer)
    field(:delay_unit, :string)
    field(:cron_expression, :string)
    field(:timezone, :string, default: "UTC")
    field(:trigger_event, :string)
    field(:trigger_data, :map, default: %{})
    field(:human_expression, :string)
  end

  @doc """
  Builds a changeset for embedded step timing configuration.
  """
  @spec changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(timing, attrs) do
    timing
    |> cast(attrs, [
      :type,
      :delay_amount,
      :delay_unit,
      :cron_expression,
      :timezone,
      :trigger_event,
      :trigger_data,
      :human_expression
    ])
    |> validate_required([:type])
    |> validate_inclusion(:type, @timing_types)
    |> validate_by_type()
  end

  @doc """
  Parses the documented human-friendly timing expressions.
  """
  @spec parse_human_friendly(String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def parse_human_friendly(expr) when is_binary(expr) do
    expr
    |> String.trim()
    |> String.downcase()
    |> do_parse_human_friendly()
  end

  @doc """
  Calculates the next runtime for a timing config.
  """
  @spec calculate_next_run(%__MODULE__{}, DateTime.t()) ::
          {:ok, DateTime.t()} | {:event, String.t()} | {:error, term()}
  def calculate_next_run(%__MODULE__{type: "immediate"}, _from), do: {:ok, DateTime.utc_now()}

  def calculate_next_run(%__MODULE__{type: "delay", delay_amount: amount, delay_unit: unit}, from) do
    {:ok, DateTime.add(from, delay_seconds(amount, unit), :second)}
  end

  def calculate_next_run(%__MODULE__{type: "event", trigger_event: event}, _from),
    do: {:event, event}

  def calculate_next_run(
        %__MODULE__{type: "cron", cron_expression: expr, timezone: timezone},
        from
      ) do
    with {:ok, cron} <- Parser.parse(expr),
         {:ok, shifted} <- DateTime.shift_zone(from, timezone || "UTC"),
         naive <- DateTime.to_naive(shifted),
         {:ok, next_naive} <- Scheduler.get_next_run_date(cron, naive),
         {:ok, next_local} <- DateTime.from_naive(next_naive, timezone || "UTC") do
      DateTime.shift_zone(next_local, "Etc/UTC")
    end
  end

  defp validate_by_type(changeset) do
    case get_field(changeset, :type) do
      "delay" -> validate_delay(changeset)
      "cron" -> validate_cron(changeset)
      "event" -> validate_required(changeset, [:trigger_event])
      _other -> changeset
    end
  end

  defp validate_delay(changeset) do
    changeset
    |> validate_required([:delay_amount, :delay_unit])
    |> validate_inclusion(:delay_unit, @delay_units)
    |> validate_number(:delay_amount, greater_than: 0)
  end

  defp validate_cron(changeset) do
    changeset
    |> validate_required([:cron_expression])
    |> validate_change(:cron_expression, fn :cron_expression, expr ->
      case normalize_cron_expression(expr) do
        {:ok, _expr} -> []
        {:error, reason} -> [cron_expression: reason]
      end
    end)
  end

  defp normalize_cron_expression(expr) do
    case parse_human_friendly(expr) do
      {:ok, %{type: "cron", cron_expression: cron}} -> {:ok, cron}
      {:ok, %{type: "delay"}} -> {:error, "delay expressions must use type=delay"}
      {:error, _reason} -> Parser.parse(expr)
    end
  end

  defp do_parse_human_friendly("@daily"), do: {:ok, %{type: "cron", cron_expression: "0 0 * * *"}}

  defp do_parse_human_friendly("@hourly"),
    do: {:ok, %{type: "cron", cron_expression: "0 * * * *"}}

  defp do_parse_human_friendly("@weekly"),
    do: {:ok, %{type: "cron", cron_expression: "0 0 * * 0"}}

  defp do_parse_human_friendly("every day at " <> time), do: parse_every_at(nil, time)

  defp do_parse_human_friendly("every " <> rest) do
    with [weekday, time] <- String.split(rest, " at ", parts: 2),
         true <- Map.has_key?(@weekdays, weekday) do
      parse_every_at(weekday, time)
    else
      _other -> {:error, "Unrecognized timing expression"}
    end
  end

  defp do_parse_human_friendly("in " <> duration), do: parse_delay(duration)
  defp do_parse_human_friendly(_expr), do: {:error, "Unrecognized timing expression"}

  defp parse_every_at(weekday, time) do
    with {:ok, {hour, minute}} <- parse_time(time) do
      weekday_part = if weekday, do: Map.fetch!(@weekdays, weekday), else: "*"
      {:ok, %{type: "cron", cron_expression: "#{minute} #{hour} * * #{weekday_part}"}}
    end
  end

  defp parse_time(time) do
    case Regex.run(~r/^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$/, String.trim(time)) do
      [_, hour, minute, meridiem] -> normalize_time(hour, minute, meridiem)
      [_, hour, minute] -> normalize_time(hour, minute, nil)
      _match -> {:error, "Invalid time"}
    end
  end

  defp normalize_time(hour, minute, meridiem) do
    hour = String.to_integer(hour)
    minute = if minute == "", do: 0, else: String.to_integer(minute)

    hour =
      case meridiem do
        "am" when hour == 12 -> 0
        "am" -> hour
        "pm" when hour == 12 -> 12
        "pm" -> hour + 12
        _none -> hour
      end

    if hour in 0..23 and minute in 0..59 do
      {:ok, {hour, minute}}
    else
      {:error, "Invalid time"}
    end
  end

  defp parse_delay(duration) do
    case Regex.run(~r/^(\d+)\s+(minute|minutes|hour|hours|day|days|week|weeks)$/, duration) do
      [_, amount, unit] ->
        {:ok,
         %{
           type: "delay",
           delay_amount: String.to_integer(amount),
           delay_unit: pluralize_unit(unit)
         }}

      _match ->
        {:error, "Invalid delay expression"}
    end
  end

  defp pluralize_unit(unit) when unit in ~w(minute minutes), do: "minutes"
  defp pluralize_unit(unit) when unit in ~w(hour hours), do: "hours"
  defp pluralize_unit(unit) when unit in ~w(day days), do: "days"
  defp pluralize_unit(unit) when unit in ~w(week weeks), do: "weeks"

  defp delay_seconds(amount, "minutes"), do: amount * 60
  defp delay_seconds(amount, "hours"), do: amount * 3_600
  defp delay_seconds(amount, "days"), do: amount * 86_400
  defp delay_seconds(amount, "weeks"), do: amount * 604_800
end
