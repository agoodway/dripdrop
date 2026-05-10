defmodule DripdropDemo.LeadNurtureHooks do
  @moduledoc """
  Demo host hooks used by the lead nurture scenario.
  """

  @doc """
  Handles DripDrop module hook calls for seeded lead nurture conditions.

  The email verification branch follows the GoodVerify.dev response shape.
  """
  @spec handle_hook(atom(), Ecto.Schema.t(), map()) :: {:ok, term()} | {:error, term()}
  def handle_hook(:verify_email, enrollment, _context) do
    email = get_in(enrollment.data || %{}, ["email"])
    blocked? = get_in(enrollment.data || %{}, ["email_verification"]) == "invalid"

    {:ok, valid_email?(email) and not blocked?}
  end

  def handle_hook(:qualification_note, enrollment, _context) do
    data = enrollment.data || %{}
    {:ok, "#{data["company"]} needs #{data["interest"]} help"}
  end

  def handle_hook(function, _enrollment, _context), do: {:error, {:unknown_hook, function}}

  defp valid_email?(email) when is_binary(email), do: String.contains?(email, "@")
  defp valid_email?(_email), do: false
end
