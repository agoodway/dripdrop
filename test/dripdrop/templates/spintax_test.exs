defmodule DripDrop.Templates.SpintaxTest do
  use ExUnit.Case, async: true

  alias DripDrop.Templates.Spintax

  test "renders deterministically for the same execution seed" do
    execution = %{id: "exec-1", attempt_window: 0}
    payload = %{subject: "{Hi|Hello|Hey}", text: "{welcome|thanks} Sam"}
    step = %{config: %{"template_variation" => %{"spintax" => true}}}

    assert Spintax.apply(payload, step, execution) == Spintax.apply(payload, step, execution)
  end

  test "attempt window participates in seed derivation" do
    assert Spintax.seed(%{id: "exec-1", attempt_window: 0}) !=
             Spintax.seed(%{id: "exec-1", attempt_window: 1})
  end

  test "nested spintax resolves inside out" do
    {rendered, _rand} = Spintax.render("{{a|b} c|d}", 123)

    assert rendered in ["a c", "b c", "d"]
  end

  test "malformed input falls back to the original text and emits telemetry" do
    attach_telemetry([:dripdrop, :template, :spintax_error])

    {rendered, _rand} = Spintax.render("{Hi|Hello", 123, %{step_execution_id: "exec-1"})

    assert rendered == "{Hi|Hello"

    assert_receive {:telemetry, [:dripdrop, :template, :spintax_error], %{count: 1},
                    %{reason: :unbalanced_braces, step_execution_id: "exec-1"}}
  end

  test "empty alternatives are filtered and emit warning" do
    attach_telemetry([:dripdrop, :template, :spintax_warning])

    {rendered, _rand} = Spintax.render("{Hi||Hello}", 123)

    assert rendered in ["Hi", "Hello"]

    assert_receive {:telemetry, [:dripdrop, :template, :spintax_warning], %{count: 1},
                    %{reason: :empty_alternative}}
  end

  test "spintax is off by default" do
    payload = %{text: "{Hi|Hello}"}
    step = %{config: %{}}
    execution = %{id: "exec-1", attempt_window: 0}

    assert Spintax.apply(payload, step, execution) == payload
  end

  test "deeply nested input resolves without stack overflow" do
    nested =
      Enum.reduce(1..20, "leaf", fn _i, acc -> "{a|#{acc}}" end)

    {rendered, _rand} = Spintax.render(nested, 123)

    assert is_binary(rendered)
    refute String.contains?(rendered, "{")
    refute String.contains?(rendered, "}")
  end

  test "non-string payload values pass through untouched" do
    payload = %{text: "{A|B}", count: 42, active: true, list: [1, 2, 3]}
    step = %{config: %{"template_variation" => %{"spintax" => true}}}
    execution = %{id: "exec-1", attempt_window: 0}

    rendered = Spintax.apply(payload, step, execution)

    assert rendered.count == 42
    assert rendered.active == true
    assert rendered.list == [1, 2, 3]
    assert rendered.text in ["A", "B"]
  end

  test "telemetry redacts text and emits only byte size + hash" do
    attach_telemetry([:dripdrop, :template, :spintax_error])

    secret_text = "Hi {{user.first_name}} you owe $1000 {bad"
    {_rendered, _rand} = Spintax.render(secret_text, 123, %{step_execution_id: "exec-1"})

    assert_receive {:telemetry, [:dripdrop, :template, :spintax_error], %{count: 1}, metadata}

    refute Map.has_key?(metadata, :text)
    assert metadata.input_byte_size == byte_size(secret_text)
    assert metadata.input_hash == :erlang.phash2(secret_text)
  end

  defp attach_telemetry(event) do
    parent = self()
    handler_id = {__MODULE__, event, System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      event,
      fn event, measurements, metadata, _config ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
