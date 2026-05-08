defmodule DripDrop.Jobs.DispatchStep do
  @moduledoc """
  Executes one scheduled step through policy, rendering, delivery, and transition handling.
  """

  import Ecto.Query

  alias DripDrop.Clock
  alias DripDrop.Conditions.Predicate
  alias DripDrop.Dispatch.Concurrency
  alias DripDrop.Dispatch.Steps, as: DispatchSteps
  alias DripDrop.Hooks.Evaluator
  alias DripDrop.Policy.AdapterPause
  alias DripDrop.Policy.Gate
  alias DripDrop.Policy.QuietHours
  alias DripDrop.Policy.RateLimit
  alias DripDrop.Policy.SendingRules
  alias DripDrop.Policy.UnsubscribeHeaders
  alias DripDrop.ShortLinks.Pipeline, as: ShortLinksPipeline
  alias DripDrop.Templates.Renderer
  alias DripDrop.Templates.Variables

  alias DripDrop.{
    ChannelAdapters,
    Channels,
    Enrollment,
    Helpers,
    HttpHook,
    MessageEvent,
    Redact,
    Repo,
    Step,
    StepExecution,
    StepTransition,
    Suppressions
  }

  use PgFlow.Job

  @job queue: :dispatch_step, max_attempts: 1, timeout: 60

  perform :dispatch do
    fn input, _ctx ->
      case __MODULE__.perform(input) do
        :ok -> %{"status" => "ok"}
        {:error, reason} -> raise "DripDrop dispatch failed: #{inspect(reason)}"
      end
    end
  end

  import PgFlow.Job, except: [perform: 1, perform: 2]

  @doc """
  Executes a scheduled step job from scheduler args.
  """
  @spec perform(term()) :: :ok | {:error, term()}
  def perform(%{args: args}) when is_map(args), do: perform(args)

  @spec perform(map()) :: :ok | {:error, term()}
  def perform(%{"step_execution_id" => step_execution_id}) do
    with {:ok, execution} <- claim(step_execution_id),
         {:ok, context} <- load_context(execution),
         :ok <- dispatch(context) do
      :ok
    else
      {:noop, :already_claimed} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(%{step_execution_id: step_execution_id}),
    do: perform(%{"step_execution_id" => step_execution_id})

  def perform(_input), do: {:error, :missing_step_execution_id}

  defp claim(step_execution_id) do
    now = Clock.now()

    StepExecution
    |> where([execution], execution.id == ^step_execution_id)
    |> where([execution], execution.state == "scheduled")
    |> select([execution], execution.id)
    |> Repo.update_all(set: [state: "claiming", claimed_at: now, updated_at: now])
    |> case do
      {1, [id]} -> {:ok, Repo.get!(StepExecution, id)}
      {0, []} -> recover_stale_sending(step_execution_id, now)
    end
  end

  defp recover_stale_sending(step_execution_id, now) do
    cutoff = Clock.shift(now, -stale_sending_seconds())

    StepExecution
    |> where([execution], execution.id == ^step_execution_id)
    |> where([execution], execution.state == "sending")
    |> where([execution], execution.claimed_at < ^cutoff)
    |> select([execution], execution.id)
    |> Repo.update_all(set: [claimed_at: now, updated_at: now])
    |> case do
      {1, [id]} -> {:ok, Repo.get!(StepExecution, id)}
      {0, []} -> {:noop, :already_claimed}
    end
  end

  defp stale_sending_seconds do
    :dripdrop
    |> Application.get_env(:dispatch_stale_after_seconds, 900)
    |> case do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _invalid -> 900
    end
  end

  defp dispatch(context) do
    with :ok <- Gate.check(policy_context(context)),
         :ok <- QuietHours.check(context) do
      deliver(context)
    else
      {:skip, reason} -> skip(context, reason)
      {:defer, defer_until, metadata} -> defer(context, defer_until, metadata)
      {:error, reason} -> fail(context, reason)
    end
  end

  defp deliver(context) do
    with {:ok, hook_results} <- resolve_hooks(context),
         {:ok, payload} <- Renderer.render_step(context.step, context.enrollment, hook_results),
         {:ok, payload} <- ShortLinksPipeline.run(payload, short_link_context(context)),
         {:ok, payload} <- UnsubscribeHeaders.apply(payload, context),
         {:ok, adapter} <-
           ChannelAdapters.select(context.step, context.sequence, context.execution),
         :ok <- AdapterPause.check(context, adapter),
         :ok <- Concurrency.check(context, adapter),
         :ok <- SendingRules.check(context, payload, adapter),
         :ok <- RateLimit.check(context, payload, adapter),
         {:ok, provider} <- Channels.provider_module(adapter.channel, adapter.provider),
         {:ok, sending} <- transition(context.execution, "sending"),
         {:ok, result} <- send_with_telemetry(context, provider, payload, sending, adapter) do
      persist_success(sending, context, adapter, payload, result)
    else
      {:skip, reason} -> skip(context, reason)
      {:defer, defer_until, reason} -> defer(context, defer_until, reason)
      {:error, reason} -> fail(context, reason)
    end
  end

  defp skip(context, reason) do
    with {:ok, skipped} <- transition(context.execution, "skipped"),
         {:ok, _event} <-
           insert_message_event(skipped, context, nil, "skipped", %{reason: reason}) do
      advance(context, skipped)
    end
  end

  defp defer(context, defer_until, metadata) do
    with {:ok, deferred} <- DispatchSteps.reschedule(context.execution, defer_until),
         {:ok, _event} <-
           insert_message_event(
             deferred,
             context,
             nil,
             "deferred",
             Map.put(metadata, :defer_until, defer_until)
           ) do
      :ok
    end
  end

  defp persist_success(execution, context, adapter, payload, result) do
    response =
      result
      |> Map.get(:response, %{})
      |> Map.put(:short_links_fallback, Map.get(payload, :short_links_fallback, false))
      |> Redact.scrub()

    attrs = %{
      state: "sent",
      executed_at: Clock.now(),
      payload: Redact.scrub(payload),
      response: response,
      provider_message_id: Map.get(result, :provider_message_id),
      metadata: success_metadata(execution, adapter, payload)
    }

    with {:ok, sent} <- execution |> StepExecution.changeset(attrs) |> Repo.update(),
         {:ok, _event} <-
           insert_message_event(
             sent,
             context,
             adapter,
             "sent",
             sent_event_data(response, sent, adapter, payload)
           ) do
      advance(context, sent)
    end
  end

  defp fail(context, reason) do
    execution =
      case Repo.get!(StepExecution, context.execution.id) do
        %StepExecution{state: "claiming"} = execution -> execution
        %StepExecution{state: "sending"} = execution -> execution
        execution -> execution
      end

    retry_count = execution.retry_count || 0
    next_retry_count = if temporary_error?(reason), do: retry_count + 1, else: retry_count

    attrs = %{
      state: "failed",
      failed_at: Clock.now(),
      retry_count: next_retry_count,
      error_message: inspect(reason),
      response: Redact.scrub(%{error: inspect(reason)})
    }

    with {:ok, failed} <- execution |> StepExecution.changeset(attrs) |> Repo.update(),
         {:ok, _event} <-
           insert_message_event(failed, context, nil, "failed", %{reason: inspect(reason)}),
         :ok <- maybe_suppress(reason, context) do
      handle_failed_execution(failed, context, reason)
    end
  end

  defp handle_failed_execution(failed, context, %{kind: :temporary} = reason) do
    if failed.retry_count < max_retries(context.step) do
      retry_at = retry_at(failed)

      with {:ok, _scheduled} <- DispatchSteps.reschedule(failed, retry_at) do
        :ok
      end
    else
      handle_exhausted_retry(context, reason)
    end
  end

  defp handle_failed_execution(_failed, _context, reason), do: {:error, reason}

  defp handle_exhausted_retry(context, reason) do
    case get_in(context.step.config || %{}, ["on_max_retry"]) do
      "continue" ->
        with :ok <- advance(context, context.execution) do
          {:error, reason}
        end

      _cancel ->
        with {:ok, _enrollment} <-
               context.enrollment
               |> Enrollment.transition_changeset("cancelled")
               |> Repo.update() do
          {:error, reason}
        end
    end
  end

  defp maybe_suppress(%{kind: :permanent, reason: {:hard_bounce, bounce_reason}}, context) do
    with {:ok, _suppression} <-
           Suppressions.suppress(%{
             tenant_key: context.execution.tenant_key,
             channel: context.execution.channel,
             recipient: context.execution.recipient,
             reason: "bounce",
             source: "provider",
             metadata: %{reason: bounce_reason, step_execution_id: context.execution.id}
           }) do
      :ok
    end
  end

  defp maybe_suppress(_reason, _context), do: :ok

  defp temporary_error?(%{kind: :temporary}), do: true
  defp temporary_error?(_reason), do: false

  defp max_retries(step) do
    case get_in(step.config || %{}, ["max_retries"]) do
      value when is_integer(value) and value >= 0 -> value
      value when is_binary(value) -> parse_max_retries(value)
      _value -> 3
    end
  end

  defp parse_max_retries(value) do
    case Integer.parse(value) do
      {retries, ""} when retries >= 0 -> retries
      _invalid -> 3
    end
  end

  defp retry_at(execution) do
    seconds = trunc(:math.pow(2, max(execution.retry_count - 1, 0))) * 30

    Clock.seconds_from_now(seconds)
  end

  defp advance(context, _execution) do
    context
    |> next_step()
    |> case do
      {:ok, %Step{} = step} -> schedule_next_step(context.enrollment, step)
      {:complete, enrollment} -> complete_enrollment(enrollment)
      :none -> :ok
    end
  end

  defp next_step(context) do
    transitions =
      StepTransition
      |> where([transition], transition.sequence_version_id == ^context.sequence_version.id)
      |> where([transition], transition.from_step_id == ^context.step.id)
      |> order_by([transition], asc: transition.priority)
      |> preload(:conditions)
      |> Repo.all()

    case transitions do
      [] ->
        linear_next_step(context)

      transitions ->
        find_transition_destination(transitions, context)
    end
  end

  defp find_transition_destination(transitions, context) do
    Enum.find_value(transitions, :none, fn transition ->
      if transition_matches?(transition, context) do
        transition_destination(transition, context)
      end
    end)
  end

  defp transition_destination(%{to_step_id: nil}, context), do: {:complete, context.enrollment}

  defp transition_destination(transition, _context),
    do: {:ok, Repo.get!(Step, transition.to_step_id)}

  defp linear_next_step(%{step: %{position: position}} = context) when is_integer(position) do
    Step
    |> where([step], step.sequence_version_id == ^context.sequence_version.id)
    |> where([step], step.active)
    |> where([step], step.position > ^position)
    |> order_by([step], asc: step.position)
    |> limit(1)
    |> Repo.one()
    |> case do
      %Step{} = step -> {:ok, step}
      nil -> {:complete, context.enrollment}
    end
  end

  defp linear_next_step(_context), do: :none

  defp transition_matches?(%{condition_mode: "always"}, _context), do: true

  defp transition_matches?(%{condition_mode: "all", conditions: conditions}, context),
    do: Enum.all?(conditions, &condition_matches?(&1, context))

  defp transition_matches?(%{condition_mode: "any", conditions: conditions}, context),
    do: Enum.any?(conditions, &condition_matches?(&1, context))

  defp condition_matches?(%{condition_type: "predicate", config: config}, context) do
    predicate = Map.get(config || %{}, "predicate") || Map.get(config || %{}, :predicate)

    case Predicate.test(predicate, predicate_context(context)) do
      {:ok, result} -> result
      {:error, reason} -> fail_closed_condition(reason, context)
    end
  end

  defp condition_matches?(%{condition_type: "enrollment_data"} = condition, context) do
    context.enrollment.data
    |> get_path(condition.field_path)
    |> compare(condition, context)
  end

  defp condition_matches?(%{condition_type: "hook"} = condition, context) do
    case Evaluator.resolve(condition, hook_context(context)) do
      {:ok, value} -> compare(value, condition, context)
      {:error, reason} -> fail_closed_condition(reason, context)
    end
  end

  defp condition_matches?(_condition, _context), do: false

  defp fail_closed_condition(reason, context) do
    :telemetry.execute([:dripdrop, :condition, :fail_closed], %{count: 1}, %{
      reason: reason,
      step_execution_id: context.execution.id
    })

    false
  end

  # Coercive comparator for `enrollment_data` and `hook` condition types.
  # Intentionally distinct from `Conditions.Predicate`, which evaluates the
  # `predicate` condition type with typed comparisons. See
  # `guides/extending.md` ("Choosing a Condition Type") — merging the two
  # would silently flip behavior for rules that compare a string
  # `expected_value` against jsonb-decoded numbers. Operator vocabulary
  # matches the Predicated DSL: `==`, `!=`, `>`, `<`, `>=`, `<=`, `in`,
  # `contains`.
  defp compare(value, %{operator: "==", expected_value: expected}, _context),
    do: to_string(value) == to_string(expected)

  defp compare(value, %{operator: "!=", expected_value: expected}, _context),
    do: to_string(value) != to_string(expected)

  defp compare(value, %{operator: "contains", expected_value: expected}, _context),
    do: String.contains?(to_string(value), to_string(expected))

  defp compare(value, %{operator: "in", expected_value: expected}, _context)
       when is_list(expected),
       do: value in expected

  defp compare(value, %{operator: operator, expected_value: expected} = condition, context)
       when operator in ~w(> >= < <=) do
    with {left, ""} <- Float.parse(to_string(value)),
         {right, ""} <- Float.parse(to_string(expected)) do
      numeric_compare(left, operator, right)
    else
      _invalid ->
        emit_coercion_error(condition, value, context)
        false
    end
  end

  defp compare(_value, _condition, _context), do: false

  defp emit_coercion_error(condition, value, context) do
    :telemetry.execute([:dripdrop, :condition, :coercion_error], %{count: 1}, %{
      condition_id: condition.id,
      step_execution_id: context.execution.id,
      condition_type: condition.condition_type,
      field_path: condition.field_path,
      hook_function: condition.hook_function,
      http_hook_id: condition.http_hook_id,
      operator: condition.operator,
      expected_value: condition.expected_value,
      actual_value: value
    })
  end

  defp numeric_compare(left, ">", right), do: left > right
  defp numeric_compare(left, ">=", right), do: left >= right
  defp numeric_compare(left, "<", right), do: left < right
  defp numeric_compare(left, "<=", right), do: left <= right

  defp resolve_hooks(context) do
    context.step.conditions
    |> Enum.filter(&(&1.condition_type == "hook"))
    |> Enum.reduce_while({:ok, %{}}, fn condition, {:ok, results} ->
      key = condition.hook_function || condition.http_hook_id

      case Evaluator.resolve(condition, hook_context(context)) do
        {:ok, value} -> {:cont, {:ok, put_hook_result(results, condition, key, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp put_hook_result(results, %{http_hook_id: http_hook_id}, key, value)
       when not is_nil(http_hook_id) do
    hook = Repo.get!(HttpHook, http_hook_id)

    results
    |> Map.put(key, value)
    |> Map.put(hook.key, value)
  end

  defp put_hook_result(results, _condition, key, value), do: Map.put(results, key, value)

  defp load_context(execution) do
    repo = Repo.repo!()

    execution =
      repo.preload(execution,
        enrollment: [sequence: [], sequence_version: []],
        step: [:conditions]
      )

    {:ok,
     %{
       execution: execution,
       enrollment: execution.enrollment,
       sequence: execution.enrollment.sequence,
       sequence_version: execution.enrollment.sequence_version,
       step: execution.step
     }}
  end

  defp policy_context(context) do
    %{
      tenant_key: context.execution.tenant_key,
      channel: context.execution.channel,
      recipient: context.execution.recipient,
      step_execution_id: context.execution.id
    }
  end

  defp hook_context(context) do
    %{
      step_execution_id: context.execution.id,
      enrollment: context.enrollment,
      sequence: context.sequence,
      step: context.step,
      vars: Variables.resolve(context.enrollment, context.step, %{})
    }
  end

  defp predicate_context(context) do
    %{
      "enrollment" => context.enrollment.data || %{},
      "sequence" => %{"key" => context.sequence.key},
      "step" => %{"key" => context.step.key, "channel" => context.step.channel}
    }
  end

  defp short_link_context(context) do
    %{
      step_execution_id: context.execution.id,
      tenant_key: context.execution.tenant_key,
      sequence: context.sequence,
      step: context.step
    }
  end

  defp delivery_step(%Step{} = step, payload, execution) do
    payload = Map.put_new(payload, :idempotency_key, execution.idempotency_key)
    config = step.config || %{}

    %{step | config: Map.put(config, "payload", payload)}
  end

  defp transition(execution, state) do
    execution
    |> StepExecution.changeset(%{state: state})
    |> Repo.update()
  end

  defp send_with_telemetry(context, provider, payload, sending, adapter) do
    metadata = telemetry_metadata(context, adapter, :send)
    start_time = System.monotonic_time()

    :telemetry.execute([:dripdrop, :dispatch, :phase, :start], %{}, metadata)

    result =
      provider.deliver(
        delivery_step(context.step, payload, sending),
        context.enrollment,
        adapter
      )

    :telemetry.execute(
      [:dripdrop, :dispatch, :phase, :stop],
      %{duration: System.monotonic_time() - start_time},
      metadata
    )

    result
  end

  defp telemetry_metadata(context, adapter, phase) do
    %{
      phase: phase,
      step_execution_id: context.execution.id,
      enrollment_id: context.enrollment.id,
      sequence_key: context.sequence.key,
      step_key: context.step.key,
      channel: context.step.channel,
      adapter_provider: adapter.provider,
      tenant_key: context.execution.tenant_key
    }
  end

  defp schedule_next_step(enrollment, step) do
    with {:ok, _execution} <- DispatchSteps.schedule(enrollment, step) do
      :ok
    end
  end

  defp complete_enrollment(%Enrollment{} = enrollment) do
    enrollment
    |> Enrollment.transition_changeset("completed")
    |> Repo.update()
    |> case do
      {:ok, _enrollment} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_message_event(execution, _context, adapter, event_type, event_data) do
    provider = if adapter, do: adapter.provider, else: "dripdrop"

    %MessageEvent{}
    |> MessageEvent.changeset(%{
      step_execution_id: execution.id,
      tenant_key: execution.tenant_key,
      channel: execution.channel,
      provider: provider,
      provider_message_id: execution.provider_message_id,
      event_type: event_type,
      event_data: event_data,
      occurred_at: Clock.now()
    })
    |> Repo.insert()
  end

  defp sent_event_data(response, execution, adapter, payload) do
    Map.merge(response, %{
      adapter_id: adapter.id,
      recipient: execution.recipient,
      sender_mailbox: sender_mailbox(payload),
      sending_domain: sending_domain(payload),
      recipient_domain: recipient_domain(execution)
    })
  end

  defp success_metadata(execution, adapter, payload) do
    execution.metadata
    |> Kernel.||(%{})
    |> Map.merge(%{
      "adapter_id" => adapter.id,
      "provider" => adapter.provider,
      "recipient" => execution.recipient,
      "sender_mailbox" => sender_mailbox(payload),
      "sending_domain" => sending_domain(payload),
      "recipient_domain" => recipient_domain(execution)
    })
  end

  defp sender_mailbox(payload) do
    case SendingRules.sender_mailbox(payload) do
      {:ok, sender_mailbox} -> sender_mailbox
      {:no_sender, _reason} -> nil
    end
  end

  defp sending_domain(payload) do
    payload
    |> outgoing_address()
    |> Helpers.email_domain()
  end

  defp recipient_domain(%{recipient: recipient}) when is_binary(recipient),
    do: Helpers.email_domain(recipient)

  defp recipient_domain(_execution), do: nil

  defp outgoing_address(payload) do
    Map.get(payload, :from) ||
      Map.get(payload, "from") ||
      Map.get(payload, :reply_to) ||
      Map.get(payload, "reply_to") ||
      Map.get(payload, "reply-to")
  end

  defp get_path(data, path), do: Helpers.get_path(data, path)
end
