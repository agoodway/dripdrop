defmodule DripDrop.Hooks.Evaluator do
  @moduledoc """
  Evaluates Elixir module hooks and HTTP hooks with bounded runtime.
  """

  alias DripDrop.{Cache, Helpers, HttpHook, Repo}
  alias DripDrop.Hooks.URLGuard
  alias DripDrop.Templates.Renderer

  @default_timeout 5_000

  @doc """
  Resolves a hook condition against a dispatch context.
  """
  @spec resolve(map(), map()) :: {:ok, term()} | {:error, term()}
  def resolve(%{hook_function: hook_function} = condition, context)
      when is_binary(hook_function) do
    cache(context, {:module, hook_function}, fn ->
      run_bounded(fn -> run_module_hook(hook_function, condition, context) end, timeout(context))
    end)
  end

  def resolve(%{http_hook_id: http_hook_id}, context) when not is_nil(http_hook_id) do
    cache(context, {:http, http_hook_id}, fn ->
      http_hook_id
      |> fetch_http_hook!()
      |> run_http_hook(vars(context))
    end)
  end

  def resolve(%{"hook_function" => hook_function} = condition, context) do
    condition
    |> atomize_keys()
    |> Map.put(:hook_function, hook_function)
    |> resolve(context)
  end

  def resolve(%{"http_hook_id" => http_hook_id}, context),
    do: resolve(%{http_hook_id: http_hook_id}, context)

  def resolve(_condition, _context), do: {:error, :no_hook}

  @doc """
  Renders and executes a configured HTTP hook.
  """
  @spec run_http_hook(Ecto.Schema.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def run_http_hook(%HttpHook{} = hook, vars, opts \\ []) do
    if Keyword.get(opts, :cache?, true) do
      run_bounded(fn -> do_run_http_hook(hook, vars) end, hook.timeout_ms || @default_timeout)
    else
      do_run_http_hook(hook, vars)
    end
  end

  defp run_module_hook(hook_function, _condition, context) do
    with {:ok, module} <- hook_module(context),
         {:ok, function} <- Helpers.existing_atom(hook_function) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(module, :handle_hook, [function, Map.get(context, :enrollment), context])
    end
  rescue
    exception ->
      :telemetry.execute([:dripdrop, :hook, :exception], %{count: 1}, %{
        exception: exception,
        stacktrace: __STACKTRACE__
      })

      {:error, :hook_exception}
  end

  defp do_run_http_hook(hook, vars) do
    with {:ok, url} <- Renderer.render_text(hook.url, vars),
         :ok <- guard_url(hook, url),
         {:ok, body} <- render_body(hook, vars),
         {:ok, response} <- request_with_retries(hook, url, body) do
      coerce_response(response, hook)
    end
  end

  defp guard_url(hook, url) do
    if req_test_stubbed?(),
      do: :ok,
      else: handle_url_validation(URLGuard.validate(url), hook, url)
  end

  defp handle_url_validation(:ok, _hook, _url), do: :ok

  defp handle_url_validation({:error, reason}, hook, url) do
    :telemetry.execute([:dripdrop, :hook, :url_blocked], %{count: 1}, %{
      http_hook_id: hook.id,
      tenant_key: hook.tenant_key,
      url: url,
      reason: reason
    })

    {:error, {:url_blocked, reason}}
  end

  defp req_test_stubbed? do
    match?({Req.Test, _name}, Keyword.get(req_options(), :plug))
  end

  defp request_with_retries(hook, url, body) do
    0..hook.retry_count
    |> Enum.reduce_while({:error, :request_failed}, fn attempt, _last_error ->
      case do_request(hook, url, body) do
        {:ok, response} ->
          {:halt, {:ok, response}}

        {:error, reason} when attempt < hook.retry_count ->
          backoff(attempt)
          {:cont, {:error, reason}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp do_request(hook, url, body) do
    opts =
      [
        method: Helpers.http_method!(hook.method),
        url: url,
        headers: headers(hook),
        receive_timeout: hook.timeout_ms,
        pool_timeout: hook.timeout_ms,
        redirect: false
      ]
      |> maybe_put_body(body)
      |> Keyword.merge(req_options())

    case Req.request(opts) do
      {:ok, %{status: status} = response} when status in 200..299 -> {:ok, response}
      {:ok, %{status: status, body: body}} -> {:error, {:http_status, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put_body(opts, nil), do: opts
  defp maybe_put_body(opts, body), do: Keyword.put(opts, :body, body)

  defp req_options do
    Application.get_env(:dripdrop, :http_hook_req_options, [])
  end

  defp headers(hook) do
    hook.headers
    |> normalize_headers()
    |> add_auth_headers(hook)
  end

  defp normalize_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_headers(_headers), do: []

  defp add_auth_headers(headers, %{auth_type: "bearer", auth_config: %{"token" => token}}) do
    [{"authorization", "Bearer #{token}"} | headers]
  end

  defp add_auth_headers(headers, %{
         auth_type: "header",
         auth_config: %{"name" => name, "value" => value}
       }) do
    [{name, value} | headers]
  end

  defp add_auth_headers(headers, _hook), do: headers

  defp render_body(%{body_template: nil}, _vars), do: {:ok, nil}

  defp render_body(%{body_template: body_template}, vars),
    do: Renderer.render_text(body_template, vars)

  defp coerce_response(%{body: body}, %{response_type: "json"}), do: {:ok, body}

  defp coerce_response(%{body: body}, %{response_type: "text"}) when is_binary(body),
    do: {:ok, body}

  defp coerce_response(%{body: body}, %{response_type: "text"}), do: {:ok, Jason.encode!(body)}

  defp coerce_response(%{body: body}, %{response_type: "number", response_path: path}) do
    body |> extract_path(path) |> coerce_number()
  end

  defp coerce_response(%{body: body}, %{response_type: "boolean", response_path: path}) do
    body |> extract_path(path) |> coerce_boolean()
  end

  defp extract_path(body, path), do: Helpers.get_path(body, path)

  defp coerce_number(value) when is_number(value), do: {:ok, value}

  defp coerce_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> {:ok, number}
      _other -> {:error, :coercion}
    end
  end

  defp coerce_number(_value), do: {:error, :coercion}

  defp coerce_boolean(value) when is_boolean(value), do: {:ok, value}
  defp coerce_boolean("true"), do: {:ok, true}
  defp coerce_boolean("false"), do: {:ok, false}
  defp coerce_boolean(_value), do: {:error, :coercion}

  defp run_bounded(fun, timeout_ms) do
    task = Task.Supervisor.async_nolink(DripDrop.TaskSupervisor, fun)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:task_exit, reason}}
      nil -> {:error, :timeout}
    end
  end

  defp cache(context, key, fun) do
    cache_key = {:dripdrop_hook_cache, Map.get(context, :step_execution_id), key}

    case Cache.lookup(cache_key) do
      {:ok, nil} ->
        cache_result(cache_key, context, fun)

      {:ok, result} ->
        result

      {:error, _reason} ->
        fun.()
    end
  end

  defp cache_result(cache_key, context, fun) do
    result = fun.()
    Cache.put(cache_key, result, ttl: timeout(context))
    result
  end

  defp vars(context), do: Map.get(context, :vars, context)
  defp timeout(context), do: Map.get(context, :timeout_ms, @default_timeout)
  defp fetch_http_hook!(id), do: Repo.repo!().get!(HttpHook, id)

  defp hook_module(%{sequence: %{hook_module: hook_module}}), do: module_from_string(hook_module)

  defp hook_module(%{sequence: %{"hook_module" => hook_module}}),
    do: module_from_string(hook_module)

  defp hook_module(_context), do: {:error, :missing_hook_module}

  defp module_from_string(module), do: Helpers.module_from_string(module, :missing_hook_module)

  defp atomize_keys(map) do
    Map.new(map, fn {key, value} -> {Helpers.atom_or_string(key), value} end)
  end

  defp backoff(attempt) do
    # Bounded inline backoff cap (5s) to avoid pinning a dispatch worker slot.
    # Full reschedule-instead-of-sleep is tracked as a follow-up.
    Process.sleep(min(5_000, trunc(:math.pow(2, attempt) * 100)))
  end
end
