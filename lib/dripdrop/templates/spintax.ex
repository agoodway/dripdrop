defmodule DripDrop.Templates.Spintax do
  @moduledoc """
  Deterministic spintax rendering for optional template variation.
  """

  @doc """
  Applies spintax to every string in a rendered payload when enabled for a step.
  """
  @spec apply(map(), map(), map()) :: map()
  def apply(payload, step, execution) do
    if enabled?(step) do
      seed = seed(execution)
      {payload, _rand} = walk(payload, rand_state(seed), context(execution))
      payload
    else
      payload
    end
  end

  @doc """
  Renders one spintax string with a deterministic seed.
  """
  @spec render(binary(), integer(), map()) :: {binary(), term()}
  def render(text, seed, metadata \\ %{}) when is_binary(text) do
    case spin(text, rand_state(seed), metadata) do
      {:ok, rendered, rand} ->
        {rendered, rand}

      {:error, reason} ->
        emit_error(reason, text, metadata)
        {text, rand_state(seed)}
    end
  end

  @doc """
  Derives the deterministic seed from a step execution.
  """
  @spec seed(map()) :: non_neg_integer()
  def seed(%{id: id, attempt_window: attempt_window}) do
    :erlang.phash2({id, attempt_window || 0})
  end

  defp enabled?(%{config: %{"template_variation" => %{"spintax" => true}}}), do: true
  defp enabled?(%{config: %{template_variation: %{spintax: true}}}), do: true
  defp enabled?(_step), do: false

  defp walk(value, rand, metadata) when is_binary(value),
    do: spin_or_original(value, rand, metadata)

  defp walk(value, rand, metadata) when is_map(value) do
    Enum.reduce(value, {%{}, rand}, fn {key, item}, {acc, rand} ->
      {item, rand} = walk(item, rand, metadata)
      {Map.put(acc, key, item), rand}
    end)
  end

  defp walk(value, rand, metadata) when is_list(value) do
    Enum.reduce(value, {[], rand}, fn item, {acc, rand} ->
      {item, rand} = walk(item, rand, metadata)
      {[item | acc], rand}
    end)
    |> then(fn {items, rand} -> {Enum.reverse(items), rand} end)
  end

  defp walk(value, rand, _metadata), do: {value, rand}

  defp spin_or_original(text, rand, metadata) do
    case spin(text, rand, metadata) do
      {:ok, rendered, rand} ->
        {rendered, rand}

      {:error, reason} ->
        emit_error(reason, text, metadata)
        {text, rand}
    end
  end

  defp spin(text, rand, metadata) do
    cond do
      not String.contains?(text, ["{", "}"]) ->
        {:ok, text, rand}

      unbalanced?(text) ->
        {:error, :unbalanced_braces}

      true ->
        reduce_tokens(text, rand, metadata)
    end
  end

  defp reduce_tokens(text, rand, metadata) do
    case innermost_tokens(text) do
      [] ->
        if String.contains?(text, ["{", "}"]) do
          {:error, :unbalanced_braces}
        else
          {:ok, text, rand}
        end

      tokens ->
        {text, rand} =
          tokens
          |> Enum.reverse()
          |> Enum.reduce({text, rand}, fn {start, stop, token}, {acc, rand} ->
            {replacement, rand} = pick(token, rand, metadata)
            {replace_range(acc, start, stop, replacement), rand}
          end)

        reduce_tokens(text, rand, metadata)
    end
  end

  defp pick(token, rand, metadata) do
    {options, warned?} =
      token
      |> String.split("|")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> then(fn options -> {options, length(options) < length(String.split(token, "|"))} end)

    if warned?, do: emit_warning(:empty_alternative, token, metadata)

    case options do
      [] ->
        {"", rand}

      options ->
        {index, rand} = :rand.uniform_s(length(options), rand)
        {Enum.at(options, index - 1), rand}
    end
  end

  defp innermost_tokens(text) do
    ~r/\{([^{}]*)\}/
    |> Regex.scan(text, return: :index)
    |> Enum.map(fn [{start, length}, {inner_start, inner_length}] ->
      {start, start + length - 1, binary_part(text, inner_start, inner_length)}
    end)
  end

  defp replace_range(text, start, stop, replacement) do
    prefix = binary_part(text, 0, start)
    suffix = binary_part(text, stop + 1, byte_size(text) - stop - 1)
    prefix <> replacement <> suffix
  end

  defp unbalanced?(text) do
    text
    |> String.graphemes()
    |> Enum.reduce_while(0, fn
      "{", count -> {:cont, count + 1}
      "}", 0 -> {:halt, :invalid}
      "}", count -> {:cont, count - 1}
      _char, count -> {:cont, count}
    end)
    |> case do
      0 -> false
      _invalid_or_count -> true
    end
  end

  defp rand_state(seed) do
    :rand.seed_s(:exsss, {seed, Bitwise.bxor(seed, 0x9E3779B9), Bitwise.bxor(seed, 0x85EBCA6B)})
  end

  defp context(execution) do
    %{
      step_execution_id: execution.id,
      attempt_window: execution.attempt_window || 0
    }
  end

  defp emit_error(reason, text, metadata) do
    :telemetry.execute([:dripdrop, :template, :spintax_error], %{count: 1}, %{
      reason: reason,
      input_byte_size: byte_size(text),
      input_hash: :erlang.phash2(text),
      step_execution_id: Map.get(metadata, :step_execution_id),
      attempt_window: Map.get(metadata, :attempt_window)
    })
  end

  defp emit_warning(reason, token, metadata) do
    :telemetry.execute([:dripdrop, :template, :spintax_warning], %{count: 1}, %{
      reason: reason,
      token_byte_size: byte_size(token),
      token_hash: :erlang.phash2(token),
      step_execution_id: Map.get(metadata, :step_execution_id),
      attempt_window: Map.get(metadata, :attempt_window)
    })
  end
end
