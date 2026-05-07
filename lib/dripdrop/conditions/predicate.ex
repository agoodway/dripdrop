defmodule DripDrop.Conditions.Predicate do
  @moduledoc """
  Predicate parsing and evaluation for condition rules.
  """

  alias Predicated.Query

  @type predicate :: binary() | [map()] | [struct()]

  @doc """
  Validates a stored predicate expression without evaluating it.
  """
  @spec validate(predicate() | nil) :: :ok | {:error, term()}
  def validate(nil), do: :ok

  def validate(predicate) when is_binary(predicate) do
    case Query.new(predicate) do
      {:ok, _predicates} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(predicate) when is_list(predicate), do: :ok
  def validate(_predicate), do: {:error, :invalid_predicate}

  @doc """
  Evaluates a predicate against runtime context.
  """
  @spec test(predicate() | nil, map()) :: {:ok, boolean()} | {:error, term()}
  def test(nil, _context), do: {:ok, true}

  def test(predicate, context) when is_binary(predicate) do
    case Query.new(predicate) do
      {:ok, predicates} -> {:ok, Predicated.test(predicates, context)}
      {:error, reason} -> {:error, reason}
    end
  end

  def test(predicate, context) when is_list(predicate),
    do: {:ok, Predicated.test(predicate, context)}

  def test(_predicate, _context), do: {:error, :invalid_predicate}

  @doc """
  Builds a Predicated query from structured condition parts.
  """
  @spec from_parts(binary() | nil, binary() | nil, term()) :: {:ok, binary()} | {:error, term()}
  def from_parts(nil, _operator, _expected), do: {:error, :missing_field_path}
  def from_parts(_field_path, nil, _expected), do: {:error, :missing_operator}

  def from_parts(field_path, operator, expected) do
    with {:ok, comparison_operator} <- comparison_operator(operator) do
      {:ok, "#{field_path} #{comparison_operator} #{literal(expected)}"}
    end
  end

  @valid_operators ~w(== != > < >= <= in contains)

  defp comparison_operator(operator) when operator in @valid_operators, do: {:ok, operator}
  defp comparison_operator(operator), do: {:error, {:unsupported_operator, operator}}

  defp literal(value) when is_binary(value), do: "'#{String.replace(value, "'", "\\'")}'"
  defp literal(value) when is_number(value), do: to_string(value)
  defp literal(value) when is_boolean(value), do: to_string(value)
  defp literal(nil), do: "nil"
  defp literal(value) when is_list(value), do: inspect(value, charlists: :as_lists)
  defp literal(value), do: value |> to_string() |> literal()
end
