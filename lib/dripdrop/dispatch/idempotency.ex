defmodule DripDrop.Dispatch.Idempotency do
  @moduledoc """
  Builds deterministic idempotency keys for step execution scheduling.
  """

  @doc """
  Returns the SHA-256 idempotency key for an enrollment, step, minute, and attempt.
  """
  @spec key(
          Ecto.UUID.t() | binary(),
          Ecto.UUID.t() | binary(),
          DateTime.t() | NaiveDateTime.t(),
          integer()
        ) ::
          binary()
  def key(enrollment_id, step_id, scheduled_for, attempt_window \\ 0) do
    scheduled_for_minute = truncate_to_minute(scheduled_for)

    :crypto.hash(
      :sha256,
      [
        to_string(enrollment_id),
        ":",
        to_string(step_id),
        ":",
        minute_string(scheduled_for_minute),
        ":",
        to_string(attempt_window)
      ]
    )
    |> Base.encode16(case: :lower)
  end

  @doc """
  Returns the schema-qualified call expression for the `idempotency_key` SQL
  function. Both the bulk seed `INSERT ... SELECT` path and the parity test
  use this — the SQL function is the single source of truth for how a digest
  is formed, eliminating Elixir/SQL drift under non-UTC server timezones.

  `enrollment_expr` is the SQL expression to use as the enrollment-id argument
  (e.g. `"enrollments.id"` for the bulk path, `"$4::uuid"` for tests).

  Positional parameters in the returned expression: `$1` step id, `$2`
  scheduled-for timestamp, `$3` attempt window.
  """
  @spec sql_call(binary(), binary()) :: binary()
  def sql_call(schema, enrollment_expr) do
    "#{schema}.idempotency_key(#{enrollment_expr}, $1::uuid, $2::timestamptz, $3::integer)"
  end

  defp truncate_to_minute(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> Map.put(:second, 0)
  end

  defp truncate_to_minute(%NaiveDateTime{} = datetime) do
    datetime
    |> NaiveDateTime.truncate(:second)
    |> Map.put(:second, 0)
  end

  defp minute_string(%DateTime{} = datetime) do
    datetime
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.to_naive()
    |> minute_string()
  end

  defp minute_string(%NaiveDateTime{} = datetime) do
    datetime
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_iso8601()
  end
end
