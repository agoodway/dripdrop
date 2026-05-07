defmodule DripDrop.OnReply do
  @moduledoc """
  Default reply handler for inbound provider events.

  Replies are recorded as message events. A step can additionally set
  `config["reply_behavior"] = "pause_enrollment"` to pause the enrollment when
  a reply is received. Host applications may configure
  `config :dripdrop, :on_reply, {Module, :fun}` to replace this behavior.
  """

  alias DripDrop.{Enrollment, Enrollments, Repo, StepExecution}

  @doc """
  Handles an inbound reply event using the configured or default reply callback.
  """
  @callback handle_reply(map(), Ecto.Schema.t() | nil) :: :ok | {:error, term()}

  @doc """
  Handles an inbound reply event using the configured or default reply callback.
  """
  @spec handle_reply(map(), Ecto.Schema.t() | nil) :: :ok | {:error, term()}
  def handle_reply(event, execution) do
    case Application.get_env(:dripdrop, :on_reply) do
      nil -> default_reply(event, execution)
      {module, function} -> apply(module, function, [event, execution])
      callback when is_function(callback, 2) -> callback.(event, execution)
    end
  end

  defp default_reply(_event, nil), do: :ok

  defp default_reply(_event, %StepExecution{} = execution) do
    execution =
      Repo.repo!().preload(execution, [:step, :enrollment])

    if pause_on_reply?(execution.step) do
      pause(execution.enrollment)
    else
      :ok
    end
  end

  defp pause_on_reply?(%{config: %{"reply_behavior" => "pause_enrollment"}}), do: true
  defp pause_on_reply?(%{config: %{reply_behavior: "pause_enrollment"}}), do: true
  defp pause_on_reply?(_step), do: false

  defp pause(%Enrollment{id: enrollment_id, tenant_key: tenant_key}) do
    case Enrollments.pause_enrollment(enrollment_id, tenant_key) do
      {:ok, _enrollment} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
