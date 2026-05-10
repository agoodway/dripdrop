defmodule DripDrop.Templates.Renderer do
  @moduledoc """
  Renders templates and validates channel payload shapes.
  """

  alias DripDrop.Helpers
  alias DripDrop.Templates.{Validators, Variables}

  @type render_error :: %{kind: :permanent, reason: term()}

  @doc """
  Renders a binary or map template and validates it for the target channel.
  """
  @spec render(binary() | map(), map(), atom() | binary()) ::
          {:ok, map()} | {:error, render_error()}
  def render(template, vars, channel) do
    with {:ok, rendered} <- render_template(template, vars),
         {:ok, rendered} <- maybe_compile_mjml(rendered, channel, vars),
         {:ok, payload} <- Validators.validate(rendered, channel, vars) do
      :telemetry.execute([:dripdrop, :template, :render], %{count: 1}, %{channel: channel})
      {:ok, payload}
    end
  end

  @doc """
  Renders a single Liquid text template.
  """
  @spec render_text(binary(), map()) :: {:ok, binary()} | {:error, render_error()}
  def render_text(template, vars) when is_binary(template), do: render_liquid(template, vars)

  @doc """
  Renders a step template with enrollment and hook data.
  """
  @spec render_step(map(), term(), map()) :: {:ok, map()} | {:error, render_error()}
  def render_step(%{template_type: "module"} = step, enrollment, hook_results) do
    with {:ok, rendered} <- render_module_template(step, enrollment, hook_results) do
      Validators.validate(rendered, step.channel, %{})
    end
  end

  def render_step(%{"template_type" => "module"} = step, enrollment, hook_results) do
    step
    |> atomize_step()
    |> render_step(enrollment, hook_results)
  end

  def render_step(step, enrollment, hook_results) do
    vars = Variables.resolve(enrollment, step, hook_results)
    render(template_content(step), vars, step_channel(step))
  end

  @doc """
  Validates Liquid syntax and MJML compilation for an optional email template.
  """
  @spec validate(binary() | map(), atom() | binary()) ::
          :ok | {:error, [{integer(), integer(), binary()}]}
  def validate(template, channel) do
    with :ok <- validate_liquid(template) do
      validate_mjml(template, channel)
    end
  end

  defp render_template(template, vars) when is_binary(template) do
    render_liquid(template, vars)
  end

  defp render_template(template, vars) when is_map(template) do
    template
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case render_value(value, vars) do
        {:ok, rendered} -> {:cont, {:ok, Map.put(acc, normalize_key(key), rendered)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp render_template(_template, _vars) do
    {:error, %{kind: :permanent, reason: :invalid_template}}
  end

  defp render_value(value, vars) when is_binary(value), do: render_liquid(value, vars)
  defp render_value(value, vars) when is_map(value), do: render_template(value, vars)

  defp render_value(value, vars) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case render_value(item, vars) do
        {:ok, rendered} -> {:cont, {:ok, [rendered | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rendered} -> {:ok, Enum.reverse(rendered)}
      error -> error
    end
  end

  defp render_value(value, _vars), do: {:ok, value}

  defp render_module_template(step, enrollment, hook_results) do
    with {:ok, module} <- module_from_template(step.template_module),
         {:ok, function} <- existing_atom(step.template_function) do
      apply(module, function, [enrollment, hook_results, channel_config(step)])
    else
      {:error, reason} -> {:error, %{kind: :permanent, reason: reason}}
    end
  end

  defp render_liquid(template, vars) do
    case Liquex.parse(template) do
      {:ok, parsed} ->
        context =
          vars
          |> Helpers.stringify_keys()
          |> Liquex.Context.new(error_mode: :warn, strict_variables: true)

        {result, context} = Liquex.render!(parsed, context)
        Enum.each(context.errors, &emit_missing_variable/1)

        {:ok, IO.iodata_to_binary(result)}

      {:error, reason, line} ->
        {:error, %{kind: :permanent, reason: {:liquid_parse, line, reason}}}
    end
  end

  defp maybe_compile_mjml(%{html: html} = rendered, channel, vars)
       when channel in [:email, "email"] do
    if mjml?(html) or mjml_format?(vars) do
      compile_mjml(rendered, html)
    else
      {:ok, rendered}
    end
  end

  defp maybe_compile_mjml(%{"html" => html} = rendered, channel, vars)
       when channel in [:email, "email"] do
    if mjml?(html) or mjml_format?(vars), do: compile_mjml(rendered, html), else: {:ok, rendered}
  end

  defp maybe_compile_mjml(rendered, _channel, _vars), do: {:ok, rendered}

  defp compile_mjml(rendered, mjml) do
    case mjml_to_html(mjml) do
      {:ok, html} -> {:ok, Map.put(rendered, :html, html)}
      {:error, errors} -> {:error, %{kind: :permanent, reason: {:mjml_compile, errors}}}
    end
  end

  defp validate_liquid(template) when is_binary(template) do
    case Liquex.parse(template) do
      {:ok, _parsed} -> :ok
      {:error, reason, line} -> {:error, [{line, 0, inspect(reason)}]}
    end
  end

  defp validate_liquid(template) when is_map(template) do
    template
    |> Map.values()
    |> Enum.reduce_while(:ok, fn
      value, :ok when is_binary(value) -> reduce_validation(validate_liquid(value))
      _value, :ok -> {:cont, :ok}
    end)
  end

  defp validate_liquid(_template), do: {:error, [{0, 0, "invalid template"}]}

  defp reduce_validation(:ok), do: {:cont, :ok}
  defp reduce_validation(error), do: {:halt, error}

  defp validate_mjml(%{html: html}, channel) when channel in [:email, "email"],
    do: validate_mjml(html)

  defp validate_mjml(%{"html" => html}, channel) when channel in [:email, "email"],
    do: validate_mjml(html)

  defp validate_mjml(_template, _channel), do: :ok

  defp validate_mjml(html) do
    if mjml?(html) do
      case mjml_to_html(html) do
        {:ok, _html} -> :ok
        {:error, reason} -> {:error, [{0, 0, inspect(reason)}]}
      end
    else
      :ok
    end
  end

  defp mjml?(value) when is_binary(value),
    do: value |> String.trim_leading() |> String.starts_with?("<mjml")

  defp mjml?(_value), do: false

  defp mjml_to_html(html) do
    if Code.ensure_loaded?(Mjml) and function_exported?(Mjml, :to_html, 1) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(Mjml, :to_html, [html])
    else
      {:error, :mjml_unavailable}
    end
  end

  defp mjml_format?(%{config: %{"body_format" => "mjml"}}), do: true
  defp mjml_format?(%{config: %{body_format: "mjml"}}), do: true
  defp mjml_format?(%{"config" => %{"body_format" => "mjml"}}), do: true
  defp mjml_format?(%{"body_format" => "mjml"}), do: true
  defp mjml_format?(%{body_format: "mjml"}), do: true
  defp mjml_format?(_vars), do: false

  defp emit_missing_variable(%Liquex.Error{reason: "Undefined variable: " <> variable}) do
    :telemetry.execute([:dripdrop, :template, :missing_variable], %{count: 1}, %{
      variable: variable
    })
  end

  defp emit_missing_variable(_error), do: :ok

  defp normalize_key(key), do: Helpers.atom_or_string(key)

  defp module_from_template(nil), do: {:error, :missing_template_module}
  defp module_from_template(module) when is_atom(module), do: {:ok, module}

  defp module_from_template(module) when is_binary(module) do
    module
    |> ensure_elixir_prefix()
    |> Helpers.existing_atom(:unknown_template_module_or_function)
  end

  defp existing_atom(nil), do: {:error, :missing_template_function}

  defp existing_atom(value) when is_binary(value) do
    Helpers.existing_atom(value, :unknown_template_module_or_function)
  end

  defp ensure_elixir_prefix("Elixir." <> _rest = module), do: module
  defp ensure_elixir_prefix(module), do: "Elixir." <> module

  defp channel_config(%{config: config}) when is_map(config), do: config
  defp channel_config(_step), do: %{}

  defp template_content(%{template_content: template_content}), do: template_content
  defp template_content(%{"template_content" => template_content}), do: template_content

  defp step_channel(%{channel: channel}), do: channel
  defp step_channel(%{"channel" => channel}), do: channel

  defp atomize_step(step), do: Helpers.atomize_existing_keys_strict(step)
end
