defmodule DripDrop.Policy.RateLimit do
  @moduledoc """
  Defers dispatch when configured sending-rate buckets are exhausted.
  """

  alias DripDrop.Helpers

  @scopes [:adapter, :provider, :domain, :recipient]

  @doc """
  Checks configured rate-limit buckets and defers when any bucket is exhausted.
  """
  @spec check(map(), map(), map()) ::
          :ok | {:defer, DateTime.t(), map()} | {:error, map()}
  def check(context, payload, adapter) do
    target = target(context, payload, adapter)

    context
    |> limits(adapter)
    |> buckets(target)
    |> Enum.reduce_while({:ok, []}, &check_bucket(&1, &2, target))
    |> rate_decision(context)
  end

  defp check_bucket(bucket, {:ok, hits}, target) do
    case backend().check(bucket, target) do
      :ok -> {:cont, {:ok, hits}}
      {:defer, defer_until, metadata} -> {:cont, {:ok, [{defer_until, metadata} | hits]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp rate_decision({:ok, []}, _context), do: :ok

  defp rate_decision({:ok, hits}, context) do
    {defer_until, metadata} = Enum.max_by(hits, fn {defer_until, _metadata} -> defer_until end)

    Enum.each(hits, fn {hit_defer_until, hit_metadata} ->
      :telemetry.execute([:dripdrop, :policy, :rate_limited], %{count: 1}, %{
        step_execution_id: context.execution.id,
        tenant_key: context.execution.tenant_key,
        channel: context.execution.channel,
        defer_until: hit_defer_until,
        scope: hit_metadata.scope,
        key: hit_metadata.key,
        limit: hit_metadata.limit,
        window_seconds: hit_metadata.window_seconds,
        used: hit_metadata.used
      })
    end)

    {:defer, defer_until, Map.put(metadata, :reason, "rate_limit")}
  end

  defp rate_decision({:error, reason}, _context),
    do: {:error, %{kind: :temporary, reason: {:rate_limit, reason}}}

  defp backend do
    Application.get_env(:dripdrop, :rate_limit_backend, DripDrop.Policy.RateLimit.Postgres)
  end

  defp buckets(limits, target) do
    Enum.flat_map(@scopes, fn scope ->
      with {:ok, limit} <- scope_limit(limits, scope),
           {:ok, key} <- scope_key(scope, target) do
        [
          Map.merge(limit, %{
            scope: scope,
            key: key,
            lock_key: "dripdrop:rate_limit:#{scope}:#{key}"
          })
        ]
      else
        _skip -> []
      end
    end)
  end

  defp limits(context, adapter) do
    %{}
    |> deep_merge(normalize_config(Application.get_env(:dripdrop, :rate_limits, %{})))
    |> deep_merge(normalize_config(config_value(adapter.config, :rate_limits, %{})))
    |> deep_merge(normalize_config(config_value(context.step.config, :rate_limits, %{})))
  end

  defp scope_limit(limits, scope) do
    limits
    |> config_value(scope, nil)
    |> normalize_limit()
  end

  defp normalize_limit(false), do: :disabled
  defp normalize_limit(nil), do: :disabled

  defp normalize_limit(limit) when is_binary(limit), do: parse_limit_string(limit)

  defp normalize_limit(limit) when is_map(limit) do
    with {:ok, count} <-
           parse_positive_integer(
             config_value(
               limit,
               :limit,
               config_value(limit, :count, config_value(limit, :max, nil))
             )
           ),
         {:ok, window_seconds} <-
           parse_window(
             config_value(
               limit,
               :window_seconds,
               config_value(limit, :period_seconds, config_value(limit, :window, nil))
             )
           ) do
      {:ok, %{limit: count, window_seconds: window_seconds}}
    else
      _invalid -> :disabled
    end
  end

  defp normalize_limit(limit) when is_list(limit) do
    limit
    |> Map.new()
    |> normalize_limit()
  end

  defp normalize_limit(_limit), do: :disabled

  defp parse_limit_string(limit) do
    case Regex.run(~r/^\s*(\d+)\s*\/\s*(\d+)?\s*([a-zA-Z]+)\s*$/, limit) do
      [_match, count, "", unit] -> parse_string_window(count, "1", unit)
      [_match, count, amount, unit] -> parse_string_window(count, amount, unit)
      _invalid -> :disabled
    end
  end

  defp parse_string_window(count, amount, unit) do
    with {:ok, count} <- parse_positive_integer(count),
         {:ok, amount} <- parse_positive_integer(amount),
         {:ok, seconds} <- unit_seconds(unit) do
      {:ok, %{limit: count, window_seconds: amount * seconds}}
    else
      _invalid -> :disabled
    end
  end

  defp parse_window(nil), do: :error
  defp parse_window(seconds) when is_integer(seconds) and seconds > 0, do: {:ok, seconds}
  defp parse_window(seconds) when is_binary(seconds), do: parse_window_string(seconds)

  defp parse_window_string(window) do
    case Regex.run(~r/^\s*(\d+)\s*([a-zA-Z]+)\s*$/, window) do
      [_match, amount, unit] ->
        with {:ok, amount} <- parse_positive_integer(amount),
             {:ok, seconds} <- unit_seconds(unit) do
          {:ok, amount * seconds}
        end

      _invalid ->
        parse_positive_integer(window)
    end
  end

  defp unit_seconds(unit) do
    case String.downcase(unit) do
      unit when unit in ["s", "sec", "secs", "second", "seconds"] -> {:ok, 1}
      unit when unit in ["m", "min", "mins", "minute", "minutes"] -> {:ok, 60}
      unit when unit in ["h", "hr", "hrs", "hour", "hours"] -> {:ok, 3_600}
      unit when unit in ["d", "day", "days"] -> {:ok, 86_400}
      _unit -> :error
    end
  end

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {value, ""} when value > 0 -> {:ok, value}
      _invalid -> :error
    end
  end

  defp parse_positive_integer(_value), do: :error

  defp scope_key(:adapter, %{adapter_id: nil}), do: :skip
  defp scope_key(:adapter, target), do: {:ok, target.adapter_id}
  defp scope_key(:provider, target), do: {:ok, "#{target.channel}:#{target.provider}"}
  defp scope_key(:domain, %{sending_domain: nil}), do: :skip
  defp scope_key(:domain, target), do: {:ok, target.sending_domain}
  defp scope_key(:recipient, %{recipient: nil}), do: :skip
  defp scope_key(:recipient, target), do: {:ok, "#{target.channel}:#{target.recipient}"}

  defp target(context, payload, adapter) do
    %{
      step_execution_id: context.execution.id,
      tenant_key: context.execution.tenant_key,
      adapter_id: adapter.id,
      channel: adapter.channel,
      provider: adapter.provider,
      recipient: context.execution.recipient,
      sending_domain: sending_domain(payload),
      metadata: %{
        rate_limit_adapter_id: adapter.id,
        rate_limit_provider: adapter.provider,
        rate_limit_recipient: context.execution.recipient,
        rate_limit_sending_domain: sending_domain(payload)
      }
    }
  end

  defp sending_domain(payload) do
    payload
    |> from_address()
    |> Helpers.email_domain()
  end

  defp from_address(payload) do
    config_value(payload, :from, nil) ||
      config_value(payload, :reply_to, nil) ||
      Map.get(payload, "reply-to")
  end

  defp normalize_config(config) when is_list(config),
    do: config |> Map.new() |> normalize_config()

  defp normalize_config(config) when is_map(config) do
    Map.new(config, fn {key, value} ->
      key =
        key
        |> to_string()
        |> String.trim()

      {key, normalize_config_value(value)}
    end)
  end

  defp normalize_config(_config), do: %{}

  defp normalize_config_value(value) when is_map(value), do: normalize_config(value)

  defp normalize_config_value(value) when is_list(value),
    do: value |> Map.new() |> normalize_config()

  defp normalize_config_value(value), do: value

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end

  defp config_value(config, key, default) when is_map(config) do
    Map.get(config, to_string(key), Map.get(config, key, default))
  end

  defp config_value(_config, _key, default), do: default
end
