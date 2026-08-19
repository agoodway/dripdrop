defmodule DripDrop.Hooks.EvaluatorTest do
  use DripDrop.DataCase, async: false

  alias DripDrop.{Fixtures, HttpHook, TestRepo}
  alias DripDrop.Hooks.Evaluator
  alias DripDrop.Templates.Renderer
  alias Ecto.Adapters.SQL
  import ExUnit.CaptureIO

  defmodule RaisingHooks do
    @moduledoc """
    Test hook module that raises so evaluator exception handling can be asserted.
    """

    @spec handle_hook(atom(), map(), map()) :: no_return()
    def handle_hook(:boom, _enrollment, _context), do: raise("boom")
  end

  defmodule CountingHooks do
    @moduledoc """
    Test hook module that records calls so evaluator caching can be asserted.
    """

    @spec handle_hook(:trial_days_remaining, map(), map()) :: {:ok, integer()}
    def handle_hook(:trial_days_remaining, _enrollment, %{test_pid: test_pid}) do
      send(test_pid, :trial_days_remaining_called)
      {:ok, 5}
    end
  end

  describe "module hooks" do
    test "returns module hook values and caches them per step execution" do
      context = %{
        step_execution_id: Ecto.UUID.generate(),
        sequence: %{hook_module: "#{CountingHooks}"},
        enrollment: %{},
        test_pid: self()
      }

      condition = %{hook_function: "trial_days_remaining"}

      assert {:ok, 5} = Evaluator.resolve(condition, context)
      assert {:ok, 5} = Evaluator.resolve(condition, context)
      assert_received :trial_days_remaining_called
      refute_received :trial_days_remaining_called
    end

    test "catches raised hooks and emits telemetry" do
      ref = make_ref()

      :telemetry.attach(
        "#{inspect(ref)}",
        [:dripdrop, :hook, :exception],
        fn _event, measurements, metadata, test_pid ->
          send(test_pid, {:hook_exception, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach("#{inspect(ref)}") end)

      context = %{sequence: %{hook_module: "#{RaisingHooks}"}, enrollment: %{}}

      assert {:error, :hook_exception} = Evaluator.resolve(%{hook_function: "boom"}, context)

      assert_receive {:hook_exception, %{count: 1},
                      %{exception: %RuntimeError{}, stacktrace: [_ | _]}}
    end
  end

  describe "HTTP hooks" do
    setup do
      previous = Application.get_env(:dripdrop, :http_hook_req_options)
      on_exit(fn -> Application.put_env(:dripdrop, :http_hook_req_options, previous) end)
      :ok
    end

    test "renders URL and body templates before making a request" do
      version = version_fixture()
      hook = http_hook(version.sequence_id, %{url: "http:///users/{{subscriber_id}}/score"})
      agent = start_supervised!({Agent, fn -> [] end})

      configure_req_stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        Agent.update(agent, &[{conn.request_path, body} | &1])
        Req.Test.json(conn, %{"score" => "85"})
      end)

      assert {:ok, 85.0} =
               Evaluator.run_http_hook(hook, %{
                 "subscriber_id" => "u_123",
                 "email" => "ada@example.com"
               })

      assert Agent.get(agent, & &1) == [
               {"/users/u_123/score", ~s({"email": "ada@example.com"})}
             ]
    end

    test "coerces numeric responses and reports coercion failures" do
      version = version_fixture()
      hook = http_hook(version.sequence_id)

      configure_req_stub(fn conn ->
        Req.Test.json(conn, %{"score" => "high"})
      end)

      assert {:error, :coercion} = Evaluator.run_http_hook(hook, %{})
    end

    test "caches repeated HTTP-hook resolution for one step execution" do
      version = version_fixture()
      hook = http_hook(version.sequence_id)
      agent = start_supervised!({Agent, fn -> 0 end})

      configure_req_stub(fn conn ->
        Agent.update(agent, &(&1 + 1))
        Req.Test.json(conn, %{"score" => "85"})
      end)

      context = %{step_execution_id: Ecto.UUID.generate(), vars: %{}}
      condition = %{http_hook_id: hook.id}

      assert {:ok, 85.0} = Evaluator.resolve(condition, context)
      assert {:ok, 85.0} = Evaluator.resolve(condition, context)
      assert Agent.get(agent, & &1) == 1
    end

    test "caches an HTTP hook across condition resolution and template variable rendering" do
      version = version_fixture()

      hook =
        http_hook(version.sequence_id, %{
          response_path: "trial_days_remaining",
          response_type: "number"
        })

      agent = start_supervised!({Agent, fn -> 0 end})

      configure_req_stub(fn conn ->
        Agent.update(agent, &(&1 + 1))
        Req.Test.json(conn, %{"trial_days_remaining" => "5"})
      end)

      context = %{step_execution_id: Ecto.UUID.generate(), vars: %{}}
      condition = %{http_hook_id: hook.id}

      assert {:ok, 5.0} = Evaluator.resolve(condition, context)
      assert {:ok, 5.0} = Evaluator.resolve(condition, context)

      assert {:ok, "5.0 days left"} =
               Renderer.render_text(
                 "{{trial_days_remaining}} days left",
                 %{"trial_days_remaining" => 5.0}
               )

      assert Agent.get(agent, & &1) == 1
    end

    test "enforces hard outer timeouts" do
      version = version_fixture()
      hook = http_hook(version.sequence_id, %{timeout_ms: 5})

      configure_req_stub(fn conn ->
        Process.sleep(50)
        Req.Test.json(conn, %{"score" => "85"})
      end)

      assert {:error, :timeout} = Evaluator.run_http_hook(hook, %{})
    end

    test "passes the hook timeout through current Req options" do
      version = version_fixture()
      hook = http_hook(version.sequence_id)

      configure_req_stub(fn conn ->
        Req.Test.json(conn, %{"score" => "85"})
      end)

      stderr =
        capture_io(:stderr, fn ->
          assert {:ok, 85.0} = Evaluator.run_http_hook(hook, %{})
        end)

      refute stderr =~ "setting `pool_timeout` is deprecated"
    end

    test "retries failed HTTP hooks up to the configured retry count" do
      version = version_fixture()
      hook = http_hook(version.sequence_id, %{retry_count: 2})
      agent = start_supervised!({Agent, fn -> 0 end})

      configure_req_stub(fn conn ->
        attempts = Agent.get_and_update(agent, &{&1 + 1, &1 + 1})

        if attempts < 3 do
          Plug.Conn.resp(conn, 503, "try again")
        else
          Req.Test.json(conn, %{"score" => "85"})
        end
      end)

      assert {:ok, 85.0} = Evaluator.run_http_hook(hook, %{})
      assert Agent.get(agent, & &1) == 3
    end

    test "rejects excessive timeout values" do
      version = version_fixture()

      assert {:error, changeset} =
               DripDrop.create_http_hook(version.sequence_id, %{
                 name: "Slow hook",
                 key: "slow",
                 method: "POST",
                 url: "http:///slow",
                 timeout_ms: 60_000,
                 retry_count: 0,
                 response_type: "json"
               })

      assert %{timeout_ms: [_message]} = errors_on(changeset)
    end

    test "stores auth credentials encrypted and keeps secrets out of raw test results" do
      version = version_fixture()

      hook =
        http_hook(version.sequence_id, %{
          auth_type: "bearer",
          auth_config: %{"token" => "secret"},
          response_path: nil,
          response_type: "json"
        })

      raw =
        SQL.query!(
          TestRepo,
          "select encode(auth_config, 'escape') from dripdrop.http_hooks where id::text = $1",
          [hook.id]
        )

      [[auth_config]] = raw.rows
      assert is_binary(auth_config)
      refute auth_config =~ "secret"

      configure_req_stub(fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer secret"]
        Req.Test.json(conn, %{"status" => "ok", "token" => "secret"})
      end)

      assert {:ok, %{"status" => "ok", "token" => "secret"}} =
               DripDrop.test_http_hook(hook.id, %{})

      reloaded = TestRepo.get!(HttpHook, hook.id)
      refute inspect(reloaded.last_test_result) =~ "secret"
    end

    test "test_http_hook stores a redacted result" do
      version = version_fixture()

      hook =
        http_hook(version.sequence_id, %{
          auth_type: "bearer",
          auth_config: %{"token" => "secret"},
          response_path: nil,
          response_type: "json"
        })

      configure_req_stub(fn conn ->
        Req.Test.json(conn, %{"score" => "85", "token" => "secret"})
      end)

      assert {:ok, %{"score" => "85", "token" => "secret"}} =
               DripDrop.test_http_hook(hook.id, %{})

      reloaded = TestRepo.get!(HttpHook, hook.id)
      refute is_nil(reloaded.last_test_at)
      refute inspect(reloaded.last_test_result) =~ "secret"
    end

    test "coerces boolean and text responses" do
      version = version_fixture()

      boolean_hook =
        http_hook(version.sequence_id, %{response_path: "eligible", response_type: "boolean"})

      configure_req_stub(fn conn ->
        Req.Test.json(conn, %{"eligible" => "true"})
      end)

      assert {:ok, true} = Evaluator.run_http_hook(boolean_hook, %{})

      text_hook =
        http_hook(version.sequence_id, %{
          response_path: nil,
          response_type: "text"
        })

      configure_req_stub(fn conn ->
        Req.Test.json(conn, %{"status" => "ok"})
      end)

      assert {:ok, encoded} = Evaluator.run_http_hook(text_hook, %{})
      assert Jason.decode!(encoded) == %{"status" => "ok"}
    end
  end

  defp configure_req_stub(plug) do
    name = :"dripdrop_hook_#{System.unique_integer([:positive])}"
    Req.Test.stub(name, plug)
    Application.put_env(:dripdrop, :http_hook_req_options, plug: {Req.Test, name})
  end

  defp version_fixture do
    sequence = Fixtures.sequence_fixture()
    Fixtures.sequence_version_fixture(sequence)
  end

  defp http_hook(sequence_id, attrs \\ %{}) do
    Fixtures.http_hook_fixture(
      sequence_id,
      Map.merge(
        %{
          method: "POST",
          url: "http:///score",
          body_template: ~s({"email": "{{email}}"}),
          timeout_ms: 1_000,
          retry_count: 0,
          response_path: "score",
          response_type: "number"
        },
        attrs
      )
    )
  end
end
