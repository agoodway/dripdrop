defmodule DripDrop.ShortLinks.PipelineTest do
  use DripDrop.DataCase, async: false
  use ExUnitProperties

  alias DripDrop.{Fixtures, ShortLink, TestRepo}
  alias DripDrop.ShortLinks.{GoodAnalytics, Pipeline, Request, Result, Webhook}

  defmodule CountingProvider do
    @moduledoc """
    Test short-link provider that records every request and returns deterministic URLs.
    """

    @behaviour DripDrop.ShortLinks.Adapter

    @impl DripDrop.ShortLinks.Adapter
    def create_link(%Request{} = request, opts) do
      agent = Keyword.fetch!(opts, :agent)
      count = Agent.get_and_update(agent, &{&1 + 1, &1 + 1})

      {:ok,
       %Result{
         short_url: "https://go.example.com/#{count}",
         provider_id: "provider_#{count}",
         response: %{"destination_url" => request.destination_url}
       }}
    end
  end

  defmodule FailingProvider do
    @moduledoc """
    Test short-link provider that returns a permanent provider error.
    """

    @behaviour DripDrop.ShortLinks.Adapter

    @impl DripDrop.ShortLinks.Adapter
    def create_link(_request, _opts) do
      {:error, %{kind: :permanent, reason: :api_down}}
    end
  end

  describe "built-in adapters" do
    test "good analytics adapter maps requests onto the in-process library API" do
      request =
        request(%{
          domain: "go.example.com",
          channel: "email",
          sequence_key: "onboarding",
          step_key: "welcome",
          metadata: %{"test_pid" => self()}
        })

      assert {:ok, %Result{short_url: "https://go.example.com/ga"}} =
               GoodAnalytics.create_link(request, workspace_id: "workspace_123")

      assert_receive {:good_analytics_args,
                      %{
                        workspace_id: "workspace_123",
                        domain: "go.example.com",
                        key: key,
                        url: "https://example.com/x",
                        link_type: "campaign",
                        utm_source: "dripdrop",
                        utm_medium: "email",
                        utm_campaign: "onboarding",
                        utm_content: "welcome",
                        external_id: "idem_123",
                        metadata: %{"test_pid" => _pid}
                      }}

      assert key == "idem_123"
    end

    test "webhook adapter posts normalized requests and parses the short URL" do
      name = :"short_link_webhook_#{System.unique_integer([:positive])}"
      parent = self()

      Req.Test.stub(name, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:webhook_request, conn.request_path, Jason.decode!(body)})

        Req.Test.json(conn, %{"shortUrl" => "https://go.example.com/webhook"})
      end)

      assert {:ok, %Result{short_url: "https://go.example.com/webhook"}} =
               Webhook.create_link(
                 request(),
                 endpoint: "http:///links",
                 req_options: [plug: {Req.Test, name}]
               )

      assert_receive {:webhook_request, "/links",
                      %{
                        "original_url" => "https://example.com/x",
                        "destination_url" => "https://example.com/x",
                        "idempotency_key" => "idem_123"
                      }}
    end
  end

  describe "provider behavior and idempotency" do
    test "none provider leaves URLs unchanged and writes no short-link row" do
      payload = %{text: "Visit https://example.com/x."}

      assert {:ok, ^payload} =
               Pipeline.run(payload, %{
                 step: step(%{"provider" => "none"}),
                 sequence: sequence()
               })

      assert TestRepo.aggregate(ShortLink, :count) == 0
    end

    test "rewrites eligible HTML and text URLs and persists separate destination rows" do
      agent = start_supervised!({Agent, fn -> 0 end})

      payload = %{
        html: ~s(<p>See <a href="https://example.com/x">here</a>.</p>),
        text: "Visit https://example.com/x and https://example.com/y."
      }

      assert {:ok, rewritten} = Pipeline.run(payload, context(agent))

      assert rewritten.html == ~s(<p>See <a href="https://go.example.com/1">here</a>.</p>)
      assert rewritten.text == "Visit https://go.example.com/1 and https://go.example.com/2."
      assert Agent.get(agent, & &1) == 2
      assert TestRepo.aggregate(ShortLink, :count) == 2
    end

    test "retry reuses existing short links without calling the provider again" do
      agent = start_supervised!({Agent, fn -> 0 end})
      payload = %{text: "Visit https://example.com/x."}
      context = context(agent)

      assert {:ok, first} = Pipeline.run(payload, context)
      assert {:ok, ^first} = Pipeline.run(payload, context)

      assert first.text == "Visit https://go.example.com/1."
      assert Agent.get(agent, & &1) == 1
      assert TestRepo.aggregate(ShortLink, :count) == 1
    end
  end

  describe "eligibility and rewriting" do
    test "skips unsubscribe, already-short, mailto, and tel links" do
      agent = start_supervised!({Agent, fn -> 0 end})

      payload = %{
        html:
          ~s(<a href="https://example.com/unsubscribe?token=abc">u</a><a href="https://go.example.com/a">s</a><a href="mailto:a@example.com">m</a><a href="tel:+15551234567">t</a>),
        text: "Privacy https://example.com/privacy and reset https://example.com/password-reset."
      }

      assert {:ok, ^payload} = Pipeline.run(payload, context(agent))
      assert Agent.get(agent, & &1) == 0
      assert TestRepo.aggregate(ShortLink, :count) == 0
    end

    test "plain-text rewriting preserves trailing punctuation outside the URL" do
      agent = start_supervised!({Agent, fn -> 0 end})

      assert {:ok, %{text: "Visit https://go.example.com/1.)"}} =
               Pipeline.run(%{text: "Visit https://example.com/x.)"}, context(agent))
    end

    test "generated HTML rewrites only href and src attribute values" do
      for {html, url} <- generated_html_cases() do
        {:ok, agent} = Agent.start_link(fn -> 0 end)

        assert {:ok, %{html: rewritten}} = Pipeline.run(%{html: html}, context(agent))

        assert rewritten
               |> String.replace("https://go.example.com/1", url)
               |> normalize_html() == normalize_html(html)

        Agent.stop(agent)
      end
    end

    test "HTML rewrite skips script and style contents" do
      agent = start_supervised!({Agent, fn -> 0 end})

      html =
        ~S"""
        <style>.hero{background:url("https://example.com/bg.png")}</style><script>location="https://example.com/js"</script><a href="https://example.com/x">Go</a>
        """

      assert {:ok, %{html: rewritten}} = Pipeline.run(%{html: html}, context(agent))

      assert rewritten =~ ~s(https://example.com/bg.png)
      assert rewritten =~ ~s(https://example.com/js)
      assert rewritten =~ ~s(href="https://go.example.com/1")
      assert Agent.get(agent, & &1) == 1
    end
  end

  describe "configuration and errors" do
    test "step-level provider override wins over global provider config" do
      previous = Application.get_env(:dripdrop, :short_links, [])
      Application.put_env(:dripdrop, :short_links, enabled: true, provider: FailingProvider)
      on_exit(fn -> Application.put_env(:dripdrop, :short_links, previous) end)

      agent = start_supervised!({Agent, fn -> 0 end})

      assert {:ok, %{text: "Visit https://go.example.com/1."}} =
               Pipeline.run(
                 %{text: "Visit https://example.com/x."},
                 context(agent, step: step(%{"provider" => CountingProvider}))
               )
    end

    test "UTM enrichment is part of the destination URL before shortening" do
      agent = start_supervised!({Agent, fn -> 0 end})

      assert {:ok, %{text: "Visit https://go.example.com/1."}} =
               Pipeline.run(
                 %{text: "Visit https://example.com/x?existing=1."},
                 context(agent,
                   step:
                     step(%{
                       "module" => CountingProvider,
                       "utm_source" => "newsletter",
                       "utm_medium" => "email",
                       "utm_campaign" => "spring",
                       "utm_content" => "cta"
                     })
                 )
               )

      row = TestRepo.one!(ShortLink)

      assert row.original_url == "https://example.com/x?existing=1"
      assert row.destination_url =~ "existing=1"
      assert row.destination_url =~ "utm_source=newsletter"
      assert row.destination_url =~ "utm_medium=email"
      assert row.destination_url =~ "utm_campaign=spring"
      assert row.destination_url =~ "utm_content=cta"
    end

    test "provider errors fail by default" do
      assert {:error, %{kind: :permanent, reason: :api_down}} =
               Pipeline.run(
                 %{text: "Visit https://example.com/x."},
                 %{step: step(%{"provider" => FailingProvider}), sequence: sequence()}
               )
    end

    test "send_originals leaves URLs unchanged and marks fallback" do
      payload = %{text: "Visit https://example.com/x."}

      assert {:ok, rewritten} =
               Pipeline.run(payload, %{
                 step: step(%{"provider" => FailingProvider, "on_error" => "send_originals"}),
                 sequence: sequence()
               })

      assert rewritten.text == payload.text
      assert rewritten.short_links_fallback
    end
  end

  describe "property: HTML rewriting preserves bytes outside href/src" do
    property "everything outside href attribute values is byte-identical after rewrite" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      try do
        check all(
                before <- safe_html_fragment(),
                between <- safe_html_fragment(),
                after_text <- safe_html_fragment(),
                inner <- safe_html_fragment()
              ) do
          original_html =
            ~s(<p>#{before}<a href="https://example.com/path">#{inner}</a>#{between}<a href="https://example.com/other">link</a>#{after_text}</p>)

          assert {:ok, rewritten} = Pipeline.run(%{html: original_html}, context(agent))

          # Strip every href="..." attribute value to compare the structural
          # envelope. Any byte difference outside the href values would
          # indicate the rewriter mutated unrelated markup.
          assert strip_url_attrs(original_html) == strip_url_attrs(rewritten.html)
        end
      after
        Agent.stop(agent)
      end
    end
  end

  defp safe_html_fragment do
    StreamData.map(StreamData.string(:alphanumeric, max_length: 30), &("text-" <> &1))
  end

  defp strip_url_attrs(html) do
    String.replace(html, ~r/href="[^"]*"/, ~s(href=""))
  end

  defp context(agent, opts \\ []) do
    step = Keyword.get_lazy(opts, :step, fn -> step(%{"module" => CountingProvider}) end)
    step_execution_id = Keyword.get_lazy(opts, :step_execution_id, &step_execution_id/0)

    %{
      step_execution_id: step_execution_id,
      tenant_key: "tenant-a",
      sequence: sequence(),
      step: step,
      provider_opts: [agent: agent]
    }
  end

  defp step_execution_id do
    sequence = Fixtures.sequence_fixture()
    version = Fixtures.sequence_version_fixture(sequence)
    step = Fixtures.step_fixture(version)
    enrollment = Fixtures.enrollment_fixture(sequence, version)

    enrollment
    |> Fixtures.step_execution_fixture(step)
    |> Map.fetch!(:id)
  end

  defp sequence do
    %{
      tenant_key: "tenant-a",
      key: "onboarding",
      metadata: %{"short_links" => %{"domain" => "go.example.com"}}
    }
  end

  defp step(short_links) do
    %{
      tenant_key: "tenant-a",
      channel: "email",
      key: "welcome",
      config: %{
        "short_links" =>
          Map.merge(
            %{
              "enabled" => true,
              "provider" => "module",
              "domain" => "go.example.com"
            },
            short_links
          )
      }
    }
  end

  defp generated_html_cases do
    [
      {~s(<p>See <a href="https://example.com/a">A</a>.</p>), "https://example.com/a"},
      {~s(<img src="https://example.com/image.png">), "https://example.com/image.png"},
      {~s(<div data-id="1"><a class="cta" href="https://example.com/q?x=1">Go</a></div>),
       "https://example.com/q?x=1"}
    ]
  end

  defp normalize_html(html), do: Floki.parse_document!(html) |> Floki.raw_html()

  defp request(attrs \\ %{}) do
    struct!(
      Request,
      Map.merge(
        %{
          original_url: "https://example.com/x",
          destination_url: "https://example.com/x",
          idempotency_key: "idem_123",
          tenant_key: "tenant-a",
          channel: "email",
          sequence_key: "onboarding",
          step_key: "welcome",
          domain: "go.example.com",
          metadata: %{},
          utm: %{}
        },
        attrs
      )
    )
  end
end

defmodule GoodAnalytics do
  @moduledoc """
  Test stand-in for a host application's GoodAnalytics dependency.
  """

  @spec create_link(map()) :: {:ok, map()}
  def create_link(args) do
    send(args.metadata["test_pid"], {:good_analytics_args, args})
    {:ok, %{short_url: "https://go.example.com/ga"}}
  end
end
