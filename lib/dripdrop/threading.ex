defmodule DripDrop.Threading do
  @moduledoc """
  Outbound email threading header generation.
  """

  import Ecto.Query

  alias DripDrop.{Helpers, Repo, StepExecution}

  @doc """
  Adds RFC 5322 threading headers to a payload and returns metadata to persist.
  """
  @spec apply(map(), map(), Ecto.Schema.t()) :: {:ok, map(), map()}
  def apply(payload, context, adapter) do
    out_message_id = generate_message_id(sending_domain(payload, adapter))
    previous_ids = previous_message_ids(context)
    headers = headers(out_message_id, previous_ids, context)
    payload = Map.update(payload, :headers, headers, &Map.merge(&1, headers))

    {:ok, payload,
     %{
       out_message_id: out_message_id,
       in_reply_to: List.last(previous_ids),
       references_list: references_list(previous_ids, context)
     }}
  end

  @doc """
  Generates a Message-ID using a UUIDv7-shaped local part.
  """
  @spec generate_message_id(binary() | nil) :: binary()
  def generate_message_id(domain) do
    domain = domain || "dripdrop.local"
    "<#{uuid7()}@#{domain}>"
  end

  defp headers(out_message_id, previous_ids, context) do
    %{"Message-ID" => out_message_id}
    |> maybe_put_reply_headers(previous_ids, context)
  end

  defp maybe_put_reply_headers(headers, _previous_ids, %{step: %{adapter_override_id: adapter_id}})
       when not is_nil(adapter_id),
       do: headers

  defp maybe_put_reply_headers(headers, [], _context), do: headers

  defp maybe_put_reply_headers(headers, previous_ids, _context) do
    headers
    |> Map.put("In-Reply-To", List.last(previous_ids))
    |> Map.put("References", Enum.join(previous_ids, " "))
  end

  defp references_list(_previous_ids, %{step: %{adapter_override_id: adapter_id}})
       when not is_nil(adapter_id),
       do: []

  defp references_list(previous_ids, _context), do: previous_ids

  defp previous_message_ids(context) do
    StepExecution
    |> where([execution], execution.enrollment_id == ^context.enrollment.id)
    |> where([execution], execution.id != ^context.execution.id)
    |> where([execution], execution.state == "sent")
    |> where([execution], not is_nil(execution.out_message_id))
    |> order_by([execution], asc: execution.executed_at, asc: execution.inserted_at)
    |> select([execution], execution.out_message_id)
    |> Repo.all()
  end

  defp sending_domain(payload, adapter) do
    payload
    |> outgoing_address(adapter)
    |> Helpers.email_domain()
  end

  defp outgoing_address(payload, adapter) do
    Map.get(payload, :from) ||
      Map.get(payload, "from") ||
      Map.get(payload, :reply_to) ||
      Map.get(payload, "reply_to") ||
      credential(adapter, :from) ||
      credential(adapter, :user_email)
  end

  defp credential(%{credentials: credentials}, key) do
    Map.get(credentials || %{}, key) || Map.get(credentials || %{}, to_string(key))
  end

  defp uuid7 do
    <<timestamp::48>> = <<System.system_time(:millisecond)::48>>
    <<rand_a::12, rand_b::62, _unused::6>> = :crypto.strong_rand_bytes(10)

    <<timestamp::48, 7::4, rand_a::12, 2::2, rand_b::62>>
    |> Base.encode16(case: :lower)
    |> format_uuid()
  end

  defp format_uuid(
         <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
           e::binary-size(12)>>
       ) do
    Enum.join([a, b, c, d, e], "-")
  end
end
