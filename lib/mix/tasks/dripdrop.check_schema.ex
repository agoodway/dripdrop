defmodule Mix.Tasks.Dripdrop.CheckSchema do
  @moduledoc """
  Verifies that the configured database has the current DripDrop schema version.
  """

  @shortdoc "Verifies the installed dripdrop schema version"

  use Mix.Task

  alias DripDrop.MixHelpers

  @required_tables ~w(adapter_pools adapter_pool_members adapter_sequence_budgets)

  @required_columns %{
    "channel_adapters" =>
      ~w(health_state health_score resting_until last_send_at daily_cap ramp_started_at ramp_increment ramp_floor min_gap_seconds),
    "enrollments" => ~w(adapter_id effective_mode),
    "sequence_versions" => ~w(mode),
    "steps" => ~w(adapter_override_id),
    "step_executions" => ~w(out_message_id),
    "message_events" => ~w(in_reply_to references_list)
  }

  @required_indexes ~w(
    adapter_pools_tenant_name_idx
    adapter_pools_global_name_idx
    adapter_pool_members_pool_adapter_idx
    adapter_sequence_budgets_adapter_sequence_idx
    adapter_pool_members_active_pool_idx
    enrollments_tenant_adapter_idx
    enrollments_tenant_effective_mode_idx
    step_executions_out_message_id_idx
    message_events_in_reply_to_idx
  )

  @required_constraints ~w(
    sequence_versions_mode_chk
    channel_adapters_health_state_chk
    channel_adapters_health_score_range_chk
    channel_adapters_daily_cap_positive_chk
    channel_adapters_ramp_increment_positive_chk
    channel_adapters_ramp_floor_nonnegative_chk
    channel_adapters_min_gap_seconds_nonnegative_chk
    enrollments_effective_mode_chk
    enrollments_outbound_pin_chk
    adapter_pools_on_pin_unavailable_chk
    adapter_pool_members_class_chk
    adapter_pool_members_weight_positive_chk
    adapter_sequence_budgets_max_share_pct_range_chk
  )

  @impl Mix.Task
  def run(args) do
    {opts, _args, _invalid} =
      OptionParser.parse(args, switches: [repo: :string, prefix: :string])

    Mix.Task.run("app.start")

    repo = MixHelpers.resolve_repo(opts[:repo])
    prefix = Keyword.get(opts, :prefix, "dripdrop")

    start_repo(repo)

    installed = installed_version(repo, prefix)
    current = DripDrop.Migration.current_version()

    if installed == current do
      verify_required_objects!(repo, prefix)
      Mix.shell().info("dripdrop schema is current at version #{current}")
    else
      Mix.raise("dripdrop schema version mismatch: installed=#{installed}, expected=#{current}")
    end
  end

  defp installed_version(repo, prefix) do
    query = """
    SELECT obj_description(c.oid)
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = $1 AND c.relname = 'dripdrop_version' AND c.relkind = 'v'
    """

    case repo.query(query, [prefix]) do
      {:ok, %{rows: [[comment]]}} when is_binary(comment) ->
        case Regex.run(~r/version=(\d+)/, comment) do
          [_, version] -> String.to_integer(version)
          _match -> 0
        end

      _other ->
        0
    end
  end

  defp verify_required_objects!(repo, prefix) do
    missing =
      []
      |> missing_tables(repo, prefix)
      |> missing_columns(repo, prefix)
      |> missing_indexes(repo, prefix)
      |> missing_constraints(repo, prefix)

    case missing do
      [] ->
        :ok

      missing ->
        missing_text = Enum.join(Enum.reverse(missing), ", ")
        Mix.raise("dripdrop schema is missing required objects: #{missing_text}")
    end
  end

  defp missing_tables(missing, repo, prefix) do
    Enum.reduce(@required_tables, missing, fn table, acc ->
      if exists?(
           repo,
           """
           SELECT 1
           FROM information_schema.tables
           WHERE table_schema = $1 AND table_name = $2
           """,
           [prefix, table]
         ) do
        acc
      else
        ["table #{table}" | acc]
      end
    end)
  end

  defp missing_columns(missing, repo, prefix) do
    @required_columns
    |> Enum.flat_map(fn {table, columns} -> Enum.map(columns, &{table, &1}) end)
    |> Enum.reduce(missing, &missing_column(&1, &2, repo, prefix))
  end

  defp missing_column({table, column}, missing, repo, prefix) do
    if exists?(
         repo,
         """
         SELECT 1
         FROM information_schema.columns
         WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
         """,
         [prefix, table, column]
       ) do
      missing
    else
      ["column #{table}.#{column}" | missing]
    end
  end

  defp missing_indexes(missing, repo, prefix) do
    Enum.reduce(@required_indexes, missing, fn index, acc ->
      if exists?(
           repo,
           """
           SELECT 1
           FROM pg_class c
           JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind = 'i'
           """,
           [prefix, index]
         ) do
        acc
      else
        ["index #{index}" | acc]
      end
    end)
  end

  defp missing_constraints(missing, repo, prefix) do
    Enum.reduce(@required_constraints, missing, fn constraint, acc ->
      if exists?(
           repo,
           """
           SELECT 1
           FROM pg_constraint c
           JOIN pg_namespace n ON n.oid = c.connamespace
           WHERE n.nspname = $1 AND c.conname = $2
           """,
           [prefix, constraint]
         ) do
        acc
      else
        ["constraint #{constraint}" | acc]
      end
    end)
  end

  defp exists?(repo, query, params) do
    case repo.query(query, params) do
      {:ok, %{num_rows: count}} when count > 0 -> true
      _other -> false
    end
  end

  defp start_repo(repo) do
    case repo.start_link(pool_size: 2) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, error} -> raise "Failed to start repo: #{inspect(error)}"
    end
  end
end
