defmodule DripDrop.Redact do
  @moduledoc """
  Redacts secrets from values before they are persisted to audit snapshots.

  Two layers run on every value:

    * **String/value pattern match** — strings are matched against the
      configured `:redaction_patterns` regexes (e.g. `Authorization: Bearer X`).

    * **Map-key name match** — when traversing a map, any key whose normalized
      name contains a sensitive token (`api_key`, `secret`, `token`, `password`,
      `authorization`, `bearer`) has its value replaced with `"[REDACTED]"`
      regardless of the value's shape. This catches `{"api_key": "live_..."}`
      that the regex pass would miss because the secret value isn't surrounded
      by the matching context.
  """

  @replacement "\\1\\2[REDACTED]"
  @key_redacted "[REDACTED]"
  @sensitive_key_pattern ~r/(api[_-]?key|secret|token|password|authorization|bearer)/i

  @doc """
  Scrubs strings, maps, lists, and tuples using configured redaction patterns.
  """
  @spec scrub(term(), [Regex.t()] | nil) :: term()
  def scrub(value, patterns \\ nil)

  def scrub(value, patterns) when is_binary(value) do
    patterns = patterns || Application.get_env(:dripdrop, :redaction_patterns, [])
    Enum.reduce(patterns, value, &Regex.replace(&1, &2, @replacement))
  end

  def scrub(value, patterns) when is_map(value) do
    Map.new(value, fn {key, item} ->
      if sensitive_key?(key) do
        {key, @key_redacted}
      else
        {key, scrub(item, patterns)}
      end
    end)
  end

  def scrub(value, patterns) when is_list(value) do
    Enum.map(value, &scrub(&1, patterns))
  end

  def scrub(value, patterns) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> scrub(patterns)
    |> List.to_tuple()
  end

  def scrub(value, _patterns), do: value

  defp sensitive_key?(key) when is_atom(key), do: sensitive_key?(Atom.to_string(key))
  defp sensitive_key?(key) when is_binary(key), do: Regex.match?(@sensitive_key_pattern, key)
  defp sensitive_key?(_key), do: false
end
