defmodule DripDrop.Templates.Variables do
  @moduledoc """
  Builds the template variable scope used during dispatch.
  """

  alias DripDrop.{Clock, Helpers}

  @doc """
  Builds the template variable map from enrollment data, system values, hooks, and step config.
  """
  @spec resolve(map(), map(), map(), map()) :: map()
  def resolve(enrollment, step, hook_results \\ %{}, system_vars \\ %{}) do
    enrollment
    |> enrollment_data()
    |> Map.merge(system_variables(enrollment, step))
    |> Map.merge(Helpers.stringify_keys(system_vars))
    |> Map.merge(Helpers.stringify_keys(hook_results))
    |> Map.merge(template_variables(step))
  end

  defp system_variables(enrollment, step) do
    %{}
    |> put_present("subscriber_id", get_in_any(enrollment, [:subscriber_id]))
    |> put_present("subscriber_type", get_in_any(enrollment, [:subscriber_type]))
    |> put_present("enrollment_id", get_in_any(enrollment, [:id]))
    |> put_present("tenant_key", get_in_any(enrollment, [:tenant_key]))
    |> put_present("step_key", get_in_any(step, [:key]))
    |> put_present("sequence_key", sequence_key(enrollment))
    |> Map.put("now_iso8601", DateTime.to_iso8601(Clock.now()))
  end

  defp enrollment_data(%{data: data}) when is_map(data), do: Helpers.stringify_keys(data)
  defp enrollment_data(%{"data" => data}) when is_map(data), do: Helpers.stringify_keys(data)
  defp enrollment_data(data) when is_map(data), do: Helpers.stringify_keys(data)
  defp enrollment_data(_data), do: %{}

  defp template_variables(%{config: %{"template_variables" => vars}}) when is_map(vars),
    do: Helpers.stringify_keys(vars)

  defp template_variables(%{config: %{template_variables: vars}}) when is_map(vars),
    do: Helpers.stringify_keys(vars)

  defp template_variables(%{"config" => %{"template_variables" => vars}}) when is_map(vars),
    do: Helpers.stringify_keys(vars)

  defp template_variables(_step), do: %{}

  defp sequence_key(%{sequence: sequence}), do: get_in_any(sequence, [:key])
  defp sequence_key(%{"sequence" => sequence}), do: get_in_any(sequence, [:key])
  defp sequence_key(_enrollment), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp get_in_any(nil, _path), do: nil

  defp get_in_any(value, [key]) when is_map(value) do
    Map.get(value, key) || Map.get(value, to_string(key))
  end
end
