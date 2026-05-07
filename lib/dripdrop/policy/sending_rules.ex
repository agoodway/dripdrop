defmodule DripDrop.Policy.SendingRules do
  @moduledoc """
  Applies optional per-step and per-adapter sending controls.

  DripDrop does not classify sequence messages into broad operating modes.
  Hosts opt into concrete rules such as recipient verification and daily
  sender-mailbox caps through step or adapter config.
  """

  alias DripDrop.{Helpers, Repo}

  @schema Application.compile_env(:dripdrop, :schema, "dripdrop")
  @default_daily_cap 50
  @max_daily_cap 500

  @spec check(map(), map(), map()) ::
          :ok | {:skip, binary()} | {:defer, DateTime.t(), map()} | {:error, map()}
  @doc """
  Applies verified-recipient and sender daily-cap rules for a dispatch attempt.
  """
  def check(context, payload, adapter) do
    with :ok <- verified_recipient(context),
         {:ok, sender_mailbox} <- sender_mailbox(payload),
         {:ok, decision} <- daily_cap_decision(context, adapter, sender_mailbox) do
      emit_decision(decision, context, adapter, sender_mailbox)
    else
      {:skip, reason} -> {:skip, reason}
      {:no_sender, _reason} -> :ok
      {:not_configured, _rule} -> :ok
      {:error, reason} -> {:error, %{kind: :temporary, reason: {:sending_rule, reason}}}
    end
  end

  @spec daily_cap(map(), map()) :: pos_integer() | nil
  @doc """
  Resolves the configured sender daily cap from step or adapter config.
  """
  def daily_cap(step, adapter) do
    cap =
      config_value(step, ["sending_rules", "daily_cap"]) ||
        config_value(step, ["daily_cap"]) ||
        config_value(adapter, ["sending_rules", "daily_cap"]) ||
        config_value(adapter, ["daily_cap"])

    if cap, do: cap |> parse_cap() |> min(@max_daily_cap)
  end

  @spec sender_mailbox(map()) :: {:ok, binary()} | {:no_sender, :missing_sender}
  @doc """
  Extracts the sender mailbox from a payload.
  """
  def sender_mailbox(payload) do
    payload
    |> from_address()
    |> Helpers.email_address()
    |> case do
      nil -> {:no_sender, :missing_sender}
      email -> {:ok, email}
    end
  end

  @spec sender_domain(map()) :: binary() | nil
  @doc """
  Extracts the sender domain from a payload or template.
  """
  def sender_domain(payload_or_template) do
    payload_or_template
    |> from_address()
    |> Helpers.email_domain()
  end

  defp verified_recipient(context) do
    if enabled?(context.step, "require_verified_recipient") do
      do_verified_recipient(context)
    else
      :ok
    end
  end

  defp do_verified_recipient(%{enrollment: %{data: data}}) when is_map(data) do
    if Map.get(data, "recipient_verified_at") || Map.get(data, :recipient_verified_at) do
      :ok
    else
      {:skip, "unverified_recipient"}
    end
  end

  defp do_verified_recipient(_context), do: {:skip, "unverified_recipient"}

  defp daily_cap_decision(context, adapter, sender_mailbox) do
    case daily_cap(context.step, adapter) do
      nil -> {:not_configured, :daily_cap}
      cap -> query_daily_cap(context, sender_mailbox, cap)
    end
  end

  defp query_daily_cap(context, sender_mailbox, cap) do
    schema = @schema
    timezone = timezone(context.step)

    sql = """
    WITH local_clock AS (
      SELECT timezone($1::text, now()) AS local_now
    ),
    bounds AS (
      SELECT
        timezone($1::text, date_trunc('day', local_now)) AS starts_at,
        timezone($1::text, date_trunc('day', local_now) + interval '1 day') AS next_day
      FROM local_clock
    ),
    sent AS (
      SELECT count(*)::int AS sent_count
      FROM #{schema}.message_events, bounds
      WHERE event_type = 'sent'
        AND occurred_at >= bounds.starts_at
        AND occurred_at < bounds.next_day
        AND (($2::text IS NULL AND tenant_key IS NULL) OR tenant_key = $2::text)
        AND event_data->>'sender_mailbox' = $3::text
    )
    SELECT sent.sent_count, bounds.next_day
    FROM sent, bounds
    """

    case Repo.query(sql, [timezone, context.execution.tenant_key, sender_mailbox]) do
      {:ok, %{rows: [[sent_count, next_day]]}} ->
        {:ok,
         %{allowed?: sent_count < cap, sent_count: sent_count, cap: cap, defer_until: next_day}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp emit_decision(%{allowed?: true}, _context, _adapter, _sender_mailbox), do: :ok

  defp emit_decision(decision, context, adapter, sender_mailbox) do
    :telemetry.execute([:dripdrop, :policy, :daily_cap], %{count: 1}, %{
      step_execution_id: context.execution.id,
      tenant_key: context.execution.tenant_key,
      adapter_id: adapter.id,
      sender_mailbox: sender_mailbox,
      sent_count: decision.sent_count,
      cap: decision.cap,
      defer_until: decision.defer_until
    })

    {:defer, decision.defer_until,
     %{
       reason: "daily_cap",
       sender_mailbox: sender_mailbox,
       sent_count: decision.sent_count,
       cap: decision.cap
     }}
  end

  defp timezone(step) do
    config_value(step, ["sending_rules", "timezone"]) ||
      config_value(step, ["timezone"]) ||
      Application.get_env(:dripdrop, :default_timezone, "Etc/UTC")
  end

  defp enabled?(source, key) do
    config_value(source, ["sending_rules", key]) == true ||
      config_value(source, [key]) == true
  end

  defp config_value(%{config: config}, path), do: get_config(config || %{}, path)
  defp config_value(_source, _path), do: nil

  defp get_config(config, [key]) when is_map(config),
    do: Helpers.fetch_string_or_atom_key(config, key)

  defp get_config(config, [key | rest]) when is_map(config) do
    config
    |> get_config([key])
    |> get_config(rest)
  end

  defp get_config(_config, _path), do: nil

  defp parse_cap(cap) when is_integer(cap) and cap > 0, do: cap

  defp parse_cap(cap) when is_binary(cap) do
    case Integer.parse(cap) do
      {cap, ""} when cap > 0 -> cap
      _invalid -> @default_daily_cap
    end
  end

  defp parse_cap(_cap), do: @default_daily_cap

  defp from_address(payload) when is_map(payload) do
    Map.get(payload, :from) ||
      Map.get(payload, "from") ||
      Map.get(payload, :reply_to) ||
      Map.get(payload, "reply_to") ||
      Map.get(payload, "reply-to")
  end

  defp from_address(_payload), do: nil
end
