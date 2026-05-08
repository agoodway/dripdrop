defmodule DripDrop.Policy.RateLimit.Postgres do
  @moduledoc """
  Postgres-backed rate-limit backend using advisory transaction locks.

  The backend counts recent sent events and in-flight executions inside the
  configured window, then returns a deferral boundary when a bucket is full.
  """

  @behaviour DripDrop.Policy.RateLimit.Backend

  alias DripDrop.{Clock, DBHelpers, Repo}

  @schema Application.compile_env(:dripdrop, :schema, "dripdrop")

  @impl true
  def check(%{limit: limit, window_seconds: window_seconds} = bucket, target) do
    window_start = Clock.seconds_from_now(-window_seconds)

    with {:ok, %{count: count, defer_until: defer_until}} <-
           check_bucket(bucket, target, window_start) do
      if count >= limit do
        {:defer, defer_until || fallback_defer_until(window_seconds),
         hit_metadata(bucket, target, count)}
      else
        :ok
      end
    end
  end

  defp check_bucket(bucket, target, window_start) do
    schema = @schema
    {sent_filter, inflight_filter, params} = scope_filters(bucket.scope, target)

    sql = """
    WITH locked AS (
      SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))
    ),
    marked AS (
      UPDATE #{schema}.step_executions
      SET metadata = coalesce(metadata, '{}'::jsonb) || $2,
          updated_at = now()
      FROM locked
      WHERE id = $3::uuid
      RETURNING id
    ),
    sent AS (
      SELECT count(*)::int AS sent_count, min(occurred_at) AS oldest_sent
      FROM #{schema}.message_events
      WHERE event_type = 'sent'
        AND occurred_at >= $4::timestamptz
        AND (($5::text IS NULL AND tenant_key IS NULL) OR tenant_key = $5::text)
        #{sent_filter}
    ),
    inflight AS (
      SELECT count(*)::int AS inflight_count, min(claimed_at) AS oldest_inflight
      FROM #{schema}.step_executions
      WHERE id <> $3::uuid
        AND state IN ('claiming', 'sending')
        AND claimed_at >= $4::timestamptz
        AND (($5::text IS NULL AND tenant_key IS NULL) OR tenant_key = $5::text)
        #{inflight_filter}
    )
    SELECT
      sent.sent_count + inflight.inflight_count AS used_count,
      CASE
        WHEN sent.oldest_sent IS NULL THEN inflight.oldest_inflight
        WHEN inflight.oldest_inflight IS NULL THEN sent.oldest_sent
        ELSE least(sent.oldest_sent, inflight.oldest_inflight)
      END AS oldest
    FROM sent, inflight
    """

    base_params = [
      bucket.lock_key,
      target.metadata,
      DBHelpers.dump_uuid(target.step_execution_id),
      window_start,
      target.tenant_key
    ]

    case Repo.query(sql, base_params ++ params) do
      {:ok, %{rows: [[count, nil]]}} ->
        {:ok, %{count: count, defer_until: nil}}

      {:ok, %{rows: [[count, oldest]]}} ->
        {:ok, %{count: count, defer_until: Clock.shift(oldest, bucket.window_seconds)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp scope_filters(:adapter, target) do
    {
      "AND event_data->>'adapter_id' = $6::text",
      "AND metadata->>'rate_limit_adapter_id' = $6::text",
      [target.adapter_id]
    }
  end

  defp scope_filters(:provider, target) do
    {
      "AND channel = $6::text AND provider = $7::text",
      "AND channel = $6::text AND metadata->>'rate_limit_provider' = $7::text",
      [target.channel, target.provider]
    }
  end

  defp scope_filters(:domain, target) do
    {
      "AND event_data->>'sending_domain' = $6::text",
      "AND metadata->>'rate_limit_sending_domain' = $6::text",
      [target.sending_domain]
    }
  end

  defp scope_filters(:recipient_domain, target) do
    {
      "AND channel = $6::text AND event_data->>'recipient_domain' = $7::text",
      "AND channel = $6::text AND metadata->>'rate_limit_recipient_domain' = $7::text",
      [target.channel, target.recipient_domain]
    }
  end

  defp scope_filters(:recipient, target) do
    {
      "AND channel = $6::text AND event_data->>'recipient' = $7::text",
      "AND channel = $6::text AND recipient = $7::text",
      [target.channel, target.recipient]
    }
  end

  defp fallback_defer_until(window_seconds), do: Clock.seconds_from_now(window_seconds)

  defp hit_metadata(bucket, target, count) do
    %{
      scope: to_string(bucket.scope),
      limit: bucket.limit,
      window_seconds: bucket.window_seconds,
      used: count,
      key: bucket.key,
      channel: target.channel,
      provider: target.provider
    }
  end
end
