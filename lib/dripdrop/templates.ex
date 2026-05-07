defmodule DripDrop.Templates do
  @moduledoc """
  Public template helpers.
  """

  alias DripDrop.Templates.Renderer

  @doc """
  Renders a template with variables for the given channel.
  """
  @spec render(term(), map(), atom() | binary()) :: {:ok, map()} | {:error, term()}
  defdelegate render(template, vars, channel), to: Renderer

  @doc """
  Renders the template configured on a step.
  """
  @spec render_step(map(), term(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate render_step(step, enrollment, hook_results \\ %{}), to: Renderer

  @doc """
  Validates Liquid and channel-specific template requirements.
  """
  @spec validate(binary() | map(), atom() | binary()) ::
          :ok | {:error, [{integer(), integer(), binary()}]}
  def validate(template, channel) do
    Renderer.validate(template, channel)
  end
end
