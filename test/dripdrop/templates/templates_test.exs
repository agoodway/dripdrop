defmodule DripDrop.TemplatesTest do
  use ExUnit.Case, async: true

  alias DripDrop.Templates
  alias DripDrop.Templates.{Renderer, Variables}

  defmodule WelcomeTemplate do
    @moduledoc """
    Test template module that returns a pre-rendered email payload.
    """

    def render(_enrollment, _hook_results, _channel_config) do
      {:ok, %{subject: "Welcome", html: "<p>Hi</p>", text: "Hi"}}
    end
  end

  describe "Liquid inline rendering" do
    test "renders enrollment variables" do
      step = %{
        channel: :sms,
        template_content: "Hi {{name}}!"
      }

      assert {:ok, %{body: "Hi Ada!", media_urls: []}} =
               Templates.render_step(step, %{data: %{"name" => "Ada"}}, %{})
    end

    test "renders missing variables as empty strings and emits telemetry" do
      ref = make_ref()

      :telemetry.attach(
        "#{inspect(ref)}",
        [:dripdrop, :template, :missing_variable],
        fn _event, measurements, metadata, test_pid ->
          send(test_pid, {:missing_variable, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach("#{inspect(ref)}") end)

      assert {:ok, %{body: "Hello ."}} =
               Templates.render("Hello {{ totally_missing }}.", %{}, :sms)

      assert_receive {:missing_variable, %{count: 1}, %{variable: "totally_missing"}}
    end

    test "does not evaluate EEx tags for inline templates" do
      step = %{
        template_type: "inline",
        channel: :sms,
        template_content: "<%= name %>"
      }

      assert {:ok, %{body: "<%= name %>"}} =
               Templates.render_step(step, %{data: %{"name" => "Ada"}}, %{})
    end
  end

  describe "module templates" do
    test "uses rendered payload returned by the configured module function" do
      step = %{
        template_type: "module",
        template_module: "#{WelcomeTemplate}",
        template_function: "render",
        channel: :email,
        config: %{"unused" => true}
      }

      assert {:ok, payload} = Templates.render_step(step, %{}, %{score: 80})
      assert payload.subject == "Welcome"
      assert payload.html == "<p>Hi</p>"
      assert payload.text == "Hi"
      assert payload.headers == %{}
    end
  end

  describe "MJML email templates" do
    test "renders Liquid before compiling MJML to HTML" do
      template = %{
        subject: "Welcome",
        html: "<mjml><mj-body>Hi {{name}}</mj-body></mjml>"
      }

      assert {:ok, payload} = Templates.render(template, %{"name" => "Ada"}, :email)
      assert payload.subject == "Welcome"
      assert payload.html =~ "<!doctype html>"
      assert payload.html =~ "Hi Ada"
    end

    test "returns a permanent MJML compile error" do
      template = %{subject: "Broken", html: "<mjml><mj-body>"}

      assert {:error, %{kind: :permanent, reason: {:mjml_compile, _errors}}} =
               Templates.render(template, %{}, :email)
    end
  end

  describe "variable scope" do
    test "hook values override enrollment data" do
      vars =
        Variables.resolve(
          %{data: %{"score" => 50}},
          %{config: %{}},
          %{score: 80}
        )

      assert {:ok, "80"} = Renderer.render_text("{{ score }}", vars)
    end

    test "system variables are available" do
      vars =
        Variables.resolve(
          %{
            id: "enr_123",
            tenant_key: "tenant-a",
            subscriber_id: "sub_123",
            subscriber_type: "lead",
            sequence: %{key: "welcome"}
          },
          %{key: "intro", config: %{}},
          %{},
          %{"now_iso8601" => "2026-05-06T12:00:00Z"}
        )

      assert {:ok, "2026-05-06T12:00:00Z"} =
               Renderer.render_text("{{ now_iso8601 }}", vars)

      assert {:ok, "tenant-a/sub_123/lead/welcome/intro/enr_123"} =
               Renderer.render_text(
                 "{{tenant_key}}/{{subscriber_id}}/{{subscriber_type}}/{{sequence_key}}/{{step_key}}/{{enrollment_id}}",
                 vars
               )
    end
  end

  describe "template validation" do
    test "rejects Liquid syntax errors" do
      assert {:error, [{1, _column, message}]} = Templates.validate("Hi {{name", :sms)
      assert message =~ "unclosed"
    end
  end

  describe "channel payload shapes" do
    test "validates email payload requirements" do
      assert {:ok, %{subject: "Welcome", text: "Hi", html: nil, headers: %{}}} =
               Templates.render(%{subject: "Welcome", text: "Hi", html: nil}, %{}, :email)

      assert {:error, %{kind: :permanent, reason: :empty_body}} =
               Templates.render(%{subject: "Welcome", text: "", html: nil}, %{}, :email)
    end

    test "enforces SMS body length cap" do
      assert {:error, %{kind: :permanent, reason: :sms_too_long}} =
               Templates.render(String.duplicate("x", 2_000), %{sms_max_chars: 1_600}, :sms)
    end

    test "renders webhook payload defaults" do
      template = %{
        url: "https://example.test/users/{{ subscriber_id }}",
        headers: %{"x-score" => "{{ score }}"},
        body: %{"name" => "{{ name }}"}
      }

      assert {:ok, payload} =
               Templates.render(
                 template,
                 %{"subscriber_id" => "sub_123", "score" => 80, "name" => "Ada"},
                 :webhook
               )

      assert payload.url == "https://example.test/users/sub_123"
      assert payload.method == :post
      assert payload.headers == %{:"x-score" => "80"}
      assert payload.body == %{name: "Ada"}
    end

    test "renders pubsub, slack, and telegram payloads" do
      assert {:ok, %{topic: "events", event: "welcome", payload: %{name: "Ada"}}} =
               Templates.render(
                 %{topic: "events", event: "welcome", payload: %{name: "{{ name }}"}},
                 %{"name" => "Ada"},
                 :pubsub
               )

      assert {:ok, %{text: "Hi Ada", blocks: nil}} =
               Templates.render("Hi {{ name }}", %{"name" => "Ada"}, :slack)

      assert {:ok, %{chat_id: "chat_123", text: "Hi Ada", parse_mode: "Markdown"}} =
               Templates.render(
                 %{chat_id: "chat_123", text: "Hi {{ name }}", parse_mode: "Markdown"},
                 %{"name" => "Ada"},
                 :telegram
               )
    end
  end

  describe "generated Liquid input safety" do
    test "arbitrary generated Liquid input never raises" do
      for input <- generated_liquid_inputs() do
        result =
          try do
            Renderer.render_text(input, %{})
          rescue
            exception -> flunk("raised #{inspect(exception)} for #{inspect(input)}")
          catch
            kind, reason -> flunk("caught #{inspect({kind, reason})} for #{inspect(input)}")
          end

        assert match?({:ok, rendered} when is_binary(rendered), result) or
                 match?({:error, %{kind: :permanent, reason: _reason}}, result)
      end
    end

    test "arbitrary missing-variable expressions substitute empty strings" do
      for variable <- generated_variable_names() do
        assert {:ok, ""} = Renderer.render_text("{{ #{variable} }}", %{})
      end
    end
  end

  defp generated_liquid_inputs do
    alphabet = String.to_charlist(" abcdefghijklmnopqrstuvwxyz0123456789{}%|-_.:/\"'")
    alphabet_length = length(alphabet)

    Enum.map(1..250, fn index ->
      length = rem(index * 13, 80)
      generated_liquid_input(length, index, alphabet, alphabet_length)
    end)
  end

  defp generated_liquid_input(0, _index, _alphabet, _alphabet_length), do: ""

  defp generated_liquid_input(length, index, alphabet, alphabet_length) do
    1..length
    |> Enum.map(fn offset ->
      Enum.at(alphabet, rem(index * 37 + offset * 17, alphabet_length))
    end)
    |> List.to_string()
  end

  defp generated_variable_names do
    Enum.map(1..250, fn index -> "missing_#{index}" end)
  end
end
