defmodule DripDrop.Policy.MessagingPolicyTest do
  use DripDrop.DataCase, async: false

  import ExUnit.CaptureLog

  alias DripDrop.Policy.{
    AdapterPause,
    BounceComplaintThresholds,
    Gate,
    QuietHours,
    RateLimit,
    SendingRules,
    UnsubscribeHeaders
  }

  alias DripDrop.{
    ChannelAdapter,
    Enrollment,
    Fixtures,
    Jobs,
    Recipients,
    Redact,
    Sequence,
    StartupCheck,
    Step,
    StepExecution,
    Suppressions
  }

  @restored_env_keys [
    :bounce_complaint_thresholds,
    :channels,
    :default_timezone,
    :pgflow,
    :quiet_hours_default,
    :quiet_hours_timezones,
    :rate_limit_backend,
    :rate_limits,
    :scheduler,
    :unsubscribe_mailto,
    :unsubscribe_url_builder
  ]

  setup do
    previous_env =
      Map.new(@restored_env_keys, fn key ->
        {key, Application.get_env(:dripdrop, key, :__missing__)}
      end)

    Application.put_env(:dripdrop, :channels, [])
    Application.put_env(:dripdrop, :default_timezone, "Etc/UTC")
    Application.put_env(:dripdrop, :pgflow, jobs: [Jobs.DispatchStep])
    Application.put_env(:dripdrop, :quiet_hours_default, {8, 21})
    Application.put_env(:dripdrop, :scheduler, DripDrop.Schedulers.Test)
    Application.delete_env(:dripdrop, :unsubscribe_url_builder)

    on_exit(fn ->
      Enum.each(previous_env, fn {key, value} -> restore_env(key, value) end)
    end)

    :ok
  end

  describe "suppression gate" do
    test "uses libphonenumber-backed E.164 normalization for valid phone numbers" do
      assert Recipients.normalize("sms", "202-555-1234") == "+12025551234"
      assert {:ok, "+442079460018"} = Recipients.normalize_phone("020 7946 0018", "GB")
    end

    test "exposes ExEmail syntax validation for email recipients" do
      assert Recipients.valid_email?("ada@example.com")
      refute Recipients.valid_email?("not an email")
    end

    test "skips suppressed recipients before rendering and emits telemetry" do
      attach_telemetry([:dripdrop, :policy, :suppressed])

      assert {:ok, _suppression} =
               Suppressions.suppress(%{
                 channel: "email",
                 recipient: " Ada@Example.com ",
                 reason: "complaint"
               })

      assert {:skip, :suppressed} =
               Gate.check(%{channel: "email", recipient: "ada@example.com", tenant_key: nil})

      assert_receive {:telemetry, [:dripdrop, :policy, :suppressed], %{count: 1},
                      %{channel: "email", tenant_key: nil}}
    end

    test "normalizes SMS recipients before checking suppressions" do
      assert {:ok, _suppression} =
               Suppressions.suppress(%{
                 channel: "sms",
                 recipient: "+15551234567",
                 reason: "manual"
               })

      assert {:skip, :suppressed} =
               Gate.check(%{channel: "sms", recipient: "(555) 123-4567"})
    end

    test "tenant-specific suppression is not treated as global when no tenant is supplied" do
      assert {:ok, _suppression} =
               Suppressions.suppress(%{
                 tenant_key: "tenant-a",
                 channel: "email",
                 recipient: "tenant-only@example.com",
                 reason: "manual"
               })

      assert :ok = Gate.check(%{channel: "email", recipient: "tenant-only@example.com"})

      assert {:skip, :suppressed} =
               Gate.check(%{
                 channel: "email",
                 recipient: "tenant-only@example.com",
                 tenant_key: "tenant-a"
               })
    end

    test "ignores contexts without a recipient" do
      assert :ok = Gate.check(%{channel: "email"})
      assert :ok = Gate.check(%{channel: "email", recipient: nil})
    end
  end

  describe "unsubscribe headers" do
    test "omits headers unless the email step opts in" do
      payload = %{headers: %{"X-Trace" => "abc"}}

      assert {:ok, ^payload} =
               UnsubscribeHeaders.apply(payload, policy_context(step: %{config: %{}}))
    end

    test "adds RFC 8058 headers for opted-in email steps" do
      Application.put_env(:dripdrop, :unsubscribe_mailto, "leave@example.com")

      Application.put_env(:dripdrop, :unsubscribe_url_builder, fn context ->
        "https://dripdrop.test/u/#{context.execution.id}"
      end)

      context = policy_context(step: %{config: %{"unsubscribe_headers" => true}})

      assert {:ok, payload} =
               UnsubscribeHeaders.apply(%{headers: %{existing: "yes"}}, context)

      assert payload.headers["existing"] == "yes"
      assert payload.headers["List-Unsubscribe"] =~ "<https://dripdrop.test/u/"
      assert payload.headers["List-Unsubscribe"] =~ "<mailto:leave@example.com>"
      assert payload.headers["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click"
    end

    test "supports nested and legacy opt-in spellings without modes" do
      Application.put_env(:dripdrop, :unsubscribe_url_builder, fn _context ->
        "https://dripdrop.test/u/nested"
      end)

      nested_context =
        policy_context(step: %{config: %{"email" => %{"unsubscribe_headers" => true}}})

      alias_context = policy_context(step: %{config: %{unsubscribe: true}})

      assert {:ok, %{headers: nested_headers}} =
               UnsubscribeHeaders.apply(%{}, nested_context)

      assert {:ok, %{headers: alias_headers}} =
               UnsubscribeHeaders.apply(%{}, alias_context)

      assert nested_headers["List-Unsubscribe"] =~ "https://dripdrop.test/u/nested"
      assert alias_headers["List-Unsubscribe"] =~ "https://dripdrop.test/u/nested"
    end

    test "does not add unsubscribe headers to non-email steps" do
      context = policy_context(step: %{channel: "sms", config: %{"unsubscribe_headers" => true}})

      assert {:ok, %{}} = UnsubscribeHeaders.apply(%{}, context)
    end

    test "returns a permanent error when opted-in headers have no URL builder" do
      context = policy_context(step: %{config: %{"unsubscribe_headers" => true}})

      assert {:error, %{kind: :permanent, reason: :unsubscribe_url_builder_unconfigured}} =
               UnsubscribeHeaders.apply(%{}, context)
    end

    test "normalizes invalid builder output into a permanent error" do
      Application.put_env(:dripdrop, :unsubscribe_url_builder, fn _context ->
        {:ok, :not_a_url}
      end)

      context = policy_context(step: %{config: %{"unsubscribe_headers" => true}})

      assert {:error, %{kind: :permanent, reason: {:invalid_unsubscribe_url, {:ok, :not_a_url}}}} =
               UnsubscribeHeaders.apply(%{}, context)
    end
  end

  describe "startup check" do
    test "reports opted-in unsubscribe steps when no URL builder is configured" do
      sequence = Fixtures.sequence_fixture()
      version = Fixtures.sequence_version_fixture(sequence)

      Fixtures.step_fixture(version, %{
        channel: "email",
        config: %{"unsubscribe_headers" => true}
      })

      log =
        capture_log(fn ->
          assert {:error, errors} = StartupCheck.run()
          assert :unsubscribe_url_builder_unconfigured in errors
        end)

      assert log =~ "unsubscribe_url_builder_unconfigured"
    end

    test "does not report unsubscribe configuration when opted-in steps have a builder" do
      sequence = Fixtures.sequence_fixture()
      version = Fixtures.sequence_version_fixture(sequence)

      Fixtures.step_fixture(version, %{
        channel: "email",
        config: %{"unsubscribe_headers" => true}
      })

      Application.put_env(:dripdrop, :unsubscribe_url_builder, fn _context ->
        "https://dripdrop.test/u/configured"
      end)

      result = capture_log(fn -> send(self(), {:startup_result, StartupCheck.run()}) end)

      assert_receive {:startup_result, :ok}
      refute result =~ "unsubscribe_url_builder_unconfigured"
    end

    test "does not require PgFlow job registration for the Oban scheduler" do
      Application.put_env(:dripdrop, :scheduler, DripDrop.Schedulers.Oban)
      Application.put_env(:dripdrop, :pgflow, jobs: [])

      assert :ok = StartupCheck.run()
    end
  end

  describe "quiet hours" do
    test "bypasses quiet hours when disabled on the step" do
      context = policy_context(step: %{config: %{"quiet_hours" => false}})

      assert :ok = QuietHours.check(context)
    end

    test "returns a permanent error for invalid hour values" do
      context =
        policy_context(step: %{config: %{"quiet_hours" => %{"start" => "x", "end" => 21}}})

      assert {:error, %{kind: :permanent, reason: {:invalid_quiet_hour, "x"}}} =
               QuietHours.check(context)
    end

    test "defers outside recipient-local quiet-hour window and emits telemetry" do
      attach_telemetry([:dripdrop, :policy, :quiet_hours])

      utc_hour = DateTime.utc_now().hour
      context = quiet_hours_context(rem(utc_hour + 1, 24), rem(utc_hour + 2, 24))

      assert {:defer, %DateTime{} = defer_until, %{reason: "quiet_hours", timezone: "Etc/UTC"}} =
               QuietHours.check(context)

      assert_receive {:telemetry, [:dripdrop, :policy, :quiet_hours], %{count: 1},
                      %{defer_until: ^defer_until, timezone: "Etc/UTC"}}
    end

    test "allows sends inside a wrapping recipient-local quiet-hour window" do
      utc_hour = DateTime.utc_now().hour
      context = quiet_hours_context(rem(utc_hour + 23, 24), rem(utc_hour + 1, 24))

      assert :ok = QuietHours.check(context)
    end
  end

  describe "sending rules" do
    test "skips when verified-recipient rule is enabled and enrollment lacks verification" do
      context =
        policy_context(
          step: %{config: %{"sending_rules" => %{"require_verified_recipient" => true}}},
          enrollment: %{data: %{}}
        )

      assert {:skip, "unverified_recipient"} =
               SendingRules.check(context, %{from: "sender@example.com"}, adapter())
    end

    test "allows verified recipients" do
      context =
        policy_context(
          step: %{config: %{"sending_rules" => %{"require_verified_recipient" => true}}},
          enrollment: %{data: %{"recipient_verified_at" => "2026-05-06T12:00:00Z"}}
        )

      assert :ok = SendingRules.check(context, %{from: "Sender <sender@example.com>"}, adapter())
    end

    test "uses step daily cap before adapter daily cap and defers at the next boundary" do
      attach_telemetry([:dripdrop, :policy, :daily_cap])

      Fixtures.message_event_fixture(%{
        tenant_key: "tenant-a",
        event_data: %{"sender_mailbox" => "sender@example.com"}
      })

      context =
        policy_context(
          step: %{config: %{"sending_rules" => %{"daily_cap" => 1, "timezone" => "Etc/UTC"}}},
          execution: %{tenant_key: "tenant-a"}
        )

      assert {:defer, %DateTime{} = defer_until, metadata} =
               SendingRules.check(
                 context,
                 %{from: "Sender <Sender@Example.com>"},
                 adapter(config: %{"sending_rules" => %{"daily_cap" => 100}})
               )

      assert metadata == %{
               reason: "daily_cap",
               sender_mailbox: "sender@example.com",
               sent_count: 1,
               cap: 1
             }

      assert_receive {:telemetry, [:dripdrop, :policy, :daily_cap], %{count: 1},
                      %{sender_mailbox: "sender@example.com", defer_until: ^defer_until}}
    end

    test "does not count another tenant's sender activity toward the current tenant cap" do
      Fixtures.message_event_fixture(%{
        tenant_key: "tenant-a",
        event_data: %{"sender_mailbox" => "sender@example.com"}
      })

      context =
        policy_context(
          step: %{config: %{"sending_rules" => %{"daily_cap" => 1}}},
          execution: %{tenant_key: "tenant-b"}
        )

      assert :ok =
               SendingRules.check(context, %{from: "sender@example.com"}, adapter())
    end

    test "does not enforce daily caps when no sender mailbox can be parsed" do
      context = policy_context(step: %{config: %{"sending_rules" => %{"daily_cap" => 1}}})

      assert :ok = SendingRules.check(context, %{}, adapter())
      assert :ok = SendingRules.check(context, %{from: "not an email"}, adapter())
    end
  end

  describe "rate limits" do
    test "defers when an adapter bucket has reached its limit" do
      attach_telemetry([:dripdrop, :policy, :rate_limited])

      adapter = Fixtures.channel_adapter_fixture()
      {step, execution} = execution_fixture_with_step(%{"rate_limits" => %{"adapter" => "1/1h"}})

      Fixtures.message_event_fixture(%{
        tenant_key: "tenant-a",
        provider: adapter.provider,
        event_data: %{"adapter_id" => adapter.id},
        occurred_at: DateTime.add(DateTime.utc_now(:second), -60, :second)
      })

      context = policy_context(step: step, execution: execution)

      assert {:defer, %DateTime{} = defer_until, metadata} =
               RateLimit.check(context, %{from: "sender@example.com"}, adapter)

      assert metadata.reason == "rate_limit"
      assert metadata.scope == "adapter"
      assert metadata.limit == 1
      assert metadata.used == 1

      assert_receive {:telemetry, [:dripdrop, :policy, :rate_limited], %{count: 1},
                      %{scope: "adapter", defer_until: ^defer_until}}

      execution = TestRepo.get!(StepExecution, execution.id)
      assert execution.metadata["rate_limit_adapter_id"] == adapter.id
    end

    test "defers when the recipient-domain bucket has reached its limit" do
      attach_telemetry([:dripdrop, :policy, :rate_limited])

      adapter = Fixtures.channel_adapter_fixture()

      {step, execution} =
        execution_fixture_with_step(%{"rate_limits" => %{"recipient_domain" => "1/1h"}})

      execution =
        TestRepo.update!(StepExecution.changeset(execution, %{recipient: "ada@gmail.com"}))

      Fixtures.message_event_fixture(%{
        tenant_key: "tenant-a",
        channel: adapter.channel,
        provider: adapter.provider,
        event_data: %{"recipient_domain" => "gmail.com"},
        occurred_at: DateTime.add(DateTime.utc_now(:second), -60, :second)
      })

      context = policy_context(step: step, execution: execution)

      assert {:defer, %DateTime{} = defer_until, metadata} =
               RateLimit.check(context, %{from: "team@example.com"}, adapter)

      assert metadata.reason == "rate_limit"
      assert metadata.scope == "recipient_domain"
      assert metadata.key == "email:gmail.com"
      assert metadata.limit == 1
      assert metadata.used == 1

      assert_receive {:telemetry, [:dripdrop, :policy, :rate_limited], %{count: 1},
                      %{scope: "recipient_domain", defer_until: ^defer_until}}
    end

    test "recipient-domain scope skips when no email-shaped recipient is present" do
      adapter =
        Fixtures.channel_adapter_fixture(%{
          channel: "sms",
          provider: "twilio",
          credentials: %{
            "account_sid" => "AC123",
            "auth_token" => "secret",
            "from" => "+15551234567"
          }
        })

      {step, execution} =
        execution_fixture_with_step(%{"rate_limits" => %{"recipient_domain" => "1/1h"}})

      execution =
        TestRepo.update!(
          StepExecution.changeset(execution, %{recipient: "+15551234567", channel: "sms"})
        )

      step = %{step | channel: "sms"}

      context = policy_context(step: step, execution: execution)

      # No prior events, no domain extractable from a phone number — bucket
      # is silently skipped and dispatch proceeds.
      assert :ok = RateLimit.check(context, %{from: "team@example.com"}, adapter)
    end

    test "recipient-domain hits do not double-count against the per-recipient bucket" do
      attach_telemetry([:dripdrop, :policy, :rate_limited])

      adapter = Fixtures.channel_adapter_fixture()

      {step, execution} =
        execution_fixture_with_step(%{
          "rate_limits" => %{
            "recipient_domain" => "1/1h",
            "recipient" => "5/1h"
          }
        })

      execution =
        TestRepo.update!(StepExecution.changeset(execution, %{recipient: "ada@gmail.com"}))

      Fixtures.message_event_fixture(%{
        tenant_key: "tenant-a",
        channel: adapter.channel,
        provider: adapter.provider,
        event_data: %{
          "recipient_domain" => "gmail.com",
          "recipient" => "other@gmail.com"
        },
        occurred_at: DateTime.add(DateTime.utc_now(:second), -60, :second)
      })

      context = policy_context(step: step, execution: execution)

      assert {:defer, %DateTime{}, metadata} =
               RateLimit.check(context, %{from: "team@example.com"}, adapter)

      # Only the recipient_domain scope should hit (one prior event for
      # gmail.com, no prior events for the specific recipient
      # ada@gmail.com).
      assert metadata.scope == "recipient_domain"

      assert_receive {:telemetry, [:dripdrop, :policy, :rate_limited], %{count: 1},
                      %{scope: "recipient_domain"}}

      refute_receive {:telemetry, [:dripdrop, :policy, :rate_limited], %{count: 1},
                      %{scope: "recipient"}}
    end

    test "tracks recipient, provider, and sender-domain buckets independently" do
      attach_telemetry([:dripdrop, :policy, :rate_limited])

      adapter = Fixtures.channel_adapter_fixture()

      {step, execution} =
        execution_fixture_with_step(%{
          "rate_limits" => %{
            "provider" => "1/1h",
            "domain" => "1/1h",
            "recipient" => "1/1h"
          }
        })

      occurred_at = DateTime.add(DateTime.utc_now(:second), -60, :second)

      insert_message_events([
        %{
          tenant_key: "tenant-a",
          channel: adapter.channel,
          provider: adapter.provider,
          event_type: "sent",
          event_data: %{},
          occurred_at: occurred_at
        },
        %{
          tenant_key: "tenant-a",
          channel: adapter.channel,
          provider: adapter.provider,
          event_type: "sent",
          event_data: %{"sending_domain" => "example.com"},
          occurred_at: occurred_at
        },
        %{
          tenant_key: "tenant-a",
          channel: adapter.channel,
          provider: adapter.provider,
          event_type: "sent",
          event_data: %{"recipient" => execution.recipient},
          occurred_at: occurred_at
        }
      ])

      context = policy_context(step: step, execution: execution)

      assert {:defer, %DateTime{}, %{reason: "rate_limit"}} =
               RateLimit.check(context, %{from: "Team <hello@example.com>"}, adapter)

      for scope <- ~w(provider domain recipient) do
        assert_receive {:telemetry, [:dripdrop, :policy, :rate_limited], %{count: 1},
                        %{scope: ^scope}}
      end
    end
  end

  describe "bounce and complaint thresholds" do
    test "pauses adapters and emits telemetry above the complaint threshold" do
      attach_telemetry([:dripdrop, :policy, :complaint_threshold])

      adapter = Fixtures.channel_adapter_fixture()

      insert_adapter_events(adapter, "sent", 1_000)
      insert_adapter_events(adapter, "complained", 4)

      assert {:ok, 1} = BounceComplaintThresholds.check_all()

      assert_receive {:telemetry, [:dripdrop, :policy, :complaint_threshold], %{rate: rate},
                      %{adapter_id: adapter_id, sent_count: 1000, complaint_count: 4}}

      assert adapter_id == adapter.id
      assert_in_delta rate, 0.004, 0.00001

      adapter = TestRepo.get!(ChannelAdapter, adapter.id)
      assert adapter.health_state == :resting
      assert %DateTime{} = adapter.resting_until
      assert adapter.config["paused_reason"] == "complaint_threshold"
      assert is_binary(adapter.config["paused_until"])
    end

    test "pauses adapters and emits telemetry above the bounce threshold" do
      attach_telemetry([:dripdrop, :policy, :bounce_threshold])

      adapter = Fixtures.channel_adapter_fixture(%{name: "Bounce SMTP"})

      insert_adapter_events(adapter, "sent", 50)
      insert_adapter_events(adapter, "bounced", 1)

      assert {:ok, 1} = BounceComplaintThresholds.check_all()

      assert_receive {:telemetry, [:dripdrop, :policy, :bounce_threshold], %{rate: rate},
                      %{adapter_id: adapter_id, sent_count: 50, bounce_count: 1}}

      assert adapter_id == adapter.id
      assert_in_delta rate, 0.02, 0.00001

      adapter = TestRepo.get!(ChannelAdapter, adapter.id)
      assert adapter.health_state == :resting
      assert adapter.config["paused_reason"] == "bounce_threshold"
    end

    test "ignores adapters below configured thresholds" do
      adapter = Fixtures.channel_adapter_fixture(%{name: "Healthy SMTP"})

      insert_adapter_events(adapter, "sent", 1_000)
      insert_adapter_events(adapter, "complained", 1)

      assert {:ok, 0} = BounceComplaintThresholds.check_all()

      adapter = TestRepo.get!(ChannelAdapter, adapter.id)
      refute Map.has_key?(adapter.config || %{}, "paused_until")
    end
  end

  describe "adapter pause enforcement" do
    test "defers dispatch when paused_until is in the future and emits telemetry" do
      attach_telemetry([:dripdrop, :policy, :adapter_paused])

      paused_until = DateTime.add(DateTime.utc_now(:second), 3600, :second)
      paused_until_iso = DateTime.to_iso8601(paused_until)

      adapter =
        adapter(
          id: Ecto.UUID.generate(),
          config: %{
            "paused_until" => paused_until_iso,
            "paused_reason" => "complaint_threshold"
          }
        )

      context = policy_context([])

      assert {:defer, ^paused_until, metadata} = AdapterPause.check(context, adapter)
      assert metadata.reason == "adapter_paused"
      assert metadata.paused_reason == "complaint_threshold"
      assert metadata.adapter_id == adapter.id

      assert_receive {:telemetry, [:dripdrop, :policy, :adapter_paused], %{count: 1},
                      %{
                        adapter_id: adapter_id,
                        paused_reason: "complaint_threshold",
                        paused_until: ^paused_until
                      }}

      assert adapter_id == adapter.id
    end

    test "permits dispatch when paused_until is in the past" do
      paused_until = DateTime.add(DateTime.utc_now(:second), -3600, :second)
      paused_until_iso = DateTime.to_iso8601(paused_until)

      adapter =
        adapter(
          config: %{
            "paused_until" => paused_until_iso,
            "paused_reason" => "complaint_threshold"
          }
        )

      assert :ok = AdapterPause.check(policy_context([]), adapter)
    end

    test "permits dispatch when adapter has no paused_until" do
      assert :ok = AdapterPause.check(policy_context([]), adapter())
      assert :ok = AdapterPause.check(policy_context([]), adapter(config: %{"other" => "value"}))
    end

    test "permits dispatch and emits parse warning for malformed paused_until" do
      attach_telemetry([:dripdrop, :policy, :adapter_paused, :parse_warning])

      adapter = adapter(config: %{"paused_until" => "not-a-real-iso-timestamp"})

      assert :ok = AdapterPause.check(policy_context([]), adapter)

      assert_receive {:telemetry, [:dripdrop, :policy, :adapter_paused, :parse_warning],
                      %{count: 1}, %{adapter_id: _, raw_value: "not-a-real-iso-timestamp"}}
    end
  end

  describe "audit redaction" do
    test "redacts secrets recursively without changing non-secret values" do
      payload = %{
        "headers" => %{
          "Authorization" => "Bearer abc123",
          "X-Trace" => "trace-id"
        },
        "body" => [
          "api_key=secret-value",
          {"password", "password: open-sesame"}
        ]
      }

      scrubbed = Redact.scrub(payload)

      # Sensitive map keys (Authorization, password) trigger full-value
      # replacement. The regex-pattern pass still handles substring redaction
      # inside non-sensitive keys (binary-only paths like list elements).
      assert scrubbed["headers"]["Authorization"] == "[REDACTED]"
      assert scrubbed["headers"]["X-Trace"] == "trace-id"
      assert Enum.at(scrubbed["body"], 0) == "api_key=[REDACTED]"
      assert Enum.at(scrubbed["body"], 1) == {"password", "password: [REDACTED]"}
    end
  end

  defp policy_context(opts) do
    step = merge_struct(Step, default_step_attrs(), Keyword.get(opts, :step, %{}))

    enrollment =
      merge_struct(Enrollment, default_enrollment_attrs(), Keyword.get(opts, :enrollment, %{}))

    execution =
      merge_struct(
        StepExecution,
        default_execution_attrs(step),
        Keyword.get(opts, :execution, %{})
      )

    sequence =
      merge_struct(
        Sequence,
        %{id: Ecto.UUID.generate(), tenant_key: "tenant-a", metadata: %{}},
        Keyword.get(opts, :sequence, %{})
      )

    %{step: step, enrollment: enrollment, execution: execution, sequence: sequence}
  end

  defp merge_struct(_module, _defaults, %{__struct__: _struct_module} = struct), do: struct
  defp merge_struct(module, defaults, attrs), do: struct(module, Map.merge(defaults, attrs))

  defp quiet_hours_context(start_hour, end_hour) do
    policy_context(
      step: %{
        config: %{
          "quiet_hours" => %{"start" => start_hour, "end" => end_hour},
          "timezone" => "Etc/UTC"
        }
      },
      enrollment: %{data: %{"timezone" => "Etc/UTC"}}
    )
  end

  defp default_step_attrs do
    %{
      id: Ecto.UUID.generate(),
      channel: "email",
      config: %{},
      tenant_key: "tenant-a"
    }
  end

  defp default_enrollment_attrs do
    %{
      id: Ecto.UUID.generate(),
      tenant_key: "tenant-a",
      data: %{},
      metadata: %{}
    }
  end

  defp default_execution_attrs(step) do
    %{
      id: Ecto.UUID.generate(),
      tenant_key: "tenant-a",
      channel: step.channel,
      recipient: "person@example.com"
    }
  end

  defp adapter(attrs \\ []) do
    struct(
      ChannelAdapter,
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          tenant_key: "tenant-a",
          channel: "email",
          provider: "test",
          config: %{}
        },
        Map.new(attrs)
      )
    )
  end

  defp execution_fixture_with_step(config) do
    sequence = Fixtures.sequence_fixture()
    version = Fixtures.sequence_version_fixture(sequence)
    step = Fixtures.step_fixture(version, %{config: config})
    enrollment = Fixtures.enrollment_fixture(sequence, version)
    execution = Fixtures.step_execution_fixture(enrollment, step)

    {step, execution}
  end

  defp insert_adapter_events(adapter, event_type, count) do
    rows =
      for index <- 1..count do
        %{
          tenant_key: adapter.tenant_key,
          channel: adapter.channel,
          provider: adapter.provider,
          provider_event_id: "#{event_type}-#{adapter.id}-#{index}",
          event_type: event_type,
          event_data: %{"adapter_id" => adapter.id},
          occurred_at: DateTime.add(DateTime.utc_now(:second), -index, :second)
        }
      end

    insert_message_events(rows)
  end

  defp insert_message_events(rows) do
    {count, nil} = TestRepo.insert_all("message_events", rows, prefix: "dripdrop")
    count
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

  defp restore_env(key, :__missing__), do: Application.delete_env(:dripdrop, key)
  defp restore_env(key, value), do: Application.put_env(:dripdrop, key, value)
end
