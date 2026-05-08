CREATE SCHEMA IF NOT EXISTS $SCHEMA$;

--SPLIT--

CREATE OR REPLACE VIEW $SCHEMA$.dripdrop_version AS SELECT 1 AS placeholder;

--SPLIT--

-- ============================================================
-- ENUM types for fields with static value sets.
-- Channel (and provider) are intentionally text because hosts can
-- register additional channels via DripDrop.Channels.register/3.
-- ============================================================
CREATE TYPE $SCHEMA$.sequence_version_state AS ENUM ('draft', 'active', 'archived');
--SPLIT--
CREATE TYPE $SCHEMA$.template_type AS ENUM ('inline', 'module', 'external');
--SPLIT--
CREATE TYPE $SCHEMA$.condition_mode AS ENUM ('always', 'all', 'any');
--SPLIT--
CREATE TYPE $SCHEMA$.http_method AS ENUM ('GET', 'POST', 'PUT', 'PATCH', 'DELETE');
--SPLIT--
CREATE TYPE $SCHEMA$.auth_type AS ENUM ('none', 'bearer', 'basic', 'header');
--SPLIT--
CREATE TYPE $SCHEMA$.response_type AS ENUM ('json', 'text', 'number', 'boolean');
--SPLIT--
CREATE TYPE $SCHEMA$.condition_type AS ENUM ('hook', 'enrollment_data', 'event', 'predicate', 'time_window');
--SPLIT--
CREATE TYPE $SCHEMA$.condition_operator AS ENUM ('==', '!=', '>', '<', '>=', '<=', 'in', 'contains');
--SPLIT--
CREATE TYPE $SCHEMA$.enrollment_state AS ENUM ('active', 'paused', 'completed', 'cancelled');
--SPLIT--
CREATE TYPE $SCHEMA$.step_execution_state AS ENUM ('scheduled', 'claiming', 'sending', 'sent', 'failed', 'skipped', 'cancelled');
--SPLIT--
CREATE TYPE $SCHEMA$.suppression_reason AS ENUM ('unsubscribe', 'bounce', 'complaint', 'manual', 'provider_block');
--SPLIT--
CREATE TYPE $SCHEMA$.message_event_type AS ENUM ('delivered', 'bounced', 'complained', 'opened', 'clicked', 'replied', 'unsubscribed', 'sent', 'failed', 'skipped', 'deferred', 'suppressed');

--SPLIT--

CREATE TABLE $SCHEMA$.sequences (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_key text,
  name text NOT NULL,
  key text NOT NULL,
  description text,
  hook_module text,
  active boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

--SPLIT--

CREATE TABLE $SCHEMA$.sequence_versions (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  sequence_id uuid NOT NULL REFERENCES $SCHEMA$.sequences(id) ON DELETE CASCADE,
  tenant_key text,
  version integer NOT NULL,
  name text,
  state $SCHEMA$.sequence_version_state NOT NULL DEFAULT 'draft',
  mode text NOT NULL DEFAULT 'lifecycle',
  config jsonb NOT NULL DEFAULT '{}'::jsonb,
  published_at timestamptz,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sequence_versions_mode_chk
    CHECK (mode IN ('lifecycle', 'outbound'))
);

--SPLIT--

CREATE TABLE $SCHEMA$.channel_adapters (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_key text,
  name text NOT NULL,
  channel text NOT NULL,
  provider text NOT NULL,
  credentials bytea,
  config jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_default boolean NOT NULL DEFAULT false,
  active boolean NOT NULL DEFAULT true,
  health_state text,
  health_score numeric,
  resting_until timestamptz,
  last_send_at timestamptz,
  daily_cap integer,
  ramp_started_at timestamptz,
  ramp_increment integer,
  ramp_floor integer,
  min_gap_seconds integer,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT channel_adapters_health_state_chk
    CHECK (health_state IS NULL OR health_state IN ('active', 'resting', 'probing', 'ramping')),
  CONSTRAINT channel_adapters_health_score_range_chk
    CHECK (health_score IS NULL OR (health_score >= 0 AND health_score <= 1)),
  CONSTRAINT channel_adapters_daily_cap_positive_chk
    CHECK (daily_cap IS NULL OR daily_cap > 0),
  CONSTRAINT channel_adapters_ramp_increment_positive_chk
    CHECK (ramp_increment IS NULL OR ramp_increment > 0),
  CONSTRAINT channel_adapters_ramp_floor_nonnegative_chk
    CHECK (ramp_floor IS NULL OR ramp_floor >= 0),
  CONSTRAINT channel_adapters_min_gap_seconds_nonnegative_chk
    CHECK (min_gap_seconds IS NULL OR min_gap_seconds >= 0)
);

--SPLIT--

CREATE OR REPLACE FUNCTION $SCHEMA$.ensure_single_default_channel_adapter()
RETURNS trigger AS $$
BEGIN
  IF NEW.is_default THEN
    UPDATE $SCHEMA$.channel_adapters
    SET is_default = false,
        updated_at = now()
    WHERE id != NEW.id
      AND channel = NEW.channel
      AND is_default
      AND (
        (NEW.tenant_key IS NULL AND tenant_key IS NULL)
        OR tenant_key = NEW.tenant_key
      );
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

--SPLIT--

CREATE TRIGGER channel_adapters_single_default
BEFORE INSERT OR UPDATE OF channel, tenant_key, is_default ON $SCHEMA$.channel_adapters
FOR EACH ROW
WHEN (NEW.is_default)
EXECUTE FUNCTION $SCHEMA$.ensure_single_default_channel_adapter();

--SPLIT--

CREATE TABLE $SCHEMA$.steps (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  sequence_version_id uuid NOT NULL REFERENCES $SCHEMA$.sequence_versions(id) ON DELETE CASCADE,
  tenant_key text,
  name text NOT NULL,
  key text NOT NULL,
  position integer,
  channel text NOT NULL,
  timing jsonb NOT NULL DEFAULT '{"type":"immediate"}'::jsonb,
  template_type $SCHEMA$.template_type NOT NULL DEFAULT 'inline',
  template_content jsonb NOT NULL DEFAULT '{}'::jsonb,
  template_module text,
  template_function text,
  channel_adapter_id uuid REFERENCES $SCHEMA$.channel_adapters(id) ON DELETE SET NULL,
  adapter_override_id uuid REFERENCES $SCHEMA$.channel_adapters(id) ON DELETE SET NULL,
  config jsonb NOT NULL DEFAULT '{}'::jsonb,
  active boolean NOT NULL DEFAULT true,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

--SPLIT--

CREATE TABLE $SCHEMA$.step_transitions (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  sequence_version_id uuid NOT NULL REFERENCES $SCHEMA$.sequence_versions(id) ON DELETE CASCADE,
  tenant_key text,
  from_step_id uuid REFERENCES $SCHEMA$.steps(id) ON DELETE CASCADE,
  to_step_id uuid REFERENCES $SCHEMA$.steps(id) ON DELETE CASCADE,
  condition_mode $SCHEMA$.condition_mode NOT NULL DEFAULT 'always',
  priority integer NOT NULL DEFAULT 0,
  config jsonb NOT NULL DEFAULT '{}'::jsonb,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

--SPLIT--

CREATE TABLE $SCHEMA$.http_hooks (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  sequence_id uuid NOT NULL REFERENCES $SCHEMA$.sequences(id) ON DELETE CASCADE,
  tenant_key text,
  name text NOT NULL,
  key text NOT NULL,
  description text,
  method $SCHEMA$.http_method NOT NULL DEFAULT 'POST',
  url text NOT NULL,
  timeout_ms integer NOT NULL DEFAULT 5000
    CONSTRAINT http_hooks_timeout_ms_range CHECK (timeout_ms > 0 AND timeout_ms <= 30000),
  retry_count integer NOT NULL DEFAULT 2
    CONSTRAINT http_hooks_retry_count_range CHECK (retry_count >= 0 AND retry_count <= 5),
  auth_type $SCHEMA$.auth_type NOT NULL DEFAULT 'none',
  auth_config bytea,
  headers jsonb NOT NULL DEFAULT '{}'::jsonb,
  body_template text,
  response_path text,
  response_type $SCHEMA$.response_type NOT NULL DEFAULT 'json',
  active boolean NOT NULL DEFAULT true,
  last_test_at timestamptz,
  last_test_result jsonb,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

--SPLIT--

CREATE TABLE $SCHEMA$.conditions (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_key text,
  step_id uuid REFERENCES $SCHEMA$.steps(id) ON DELETE CASCADE,
  transition_id uuid REFERENCES $SCHEMA$.step_transitions(id) ON DELETE CASCADE,
  condition_type $SCHEMA$.condition_type NOT NULL,
  operator $SCHEMA$.condition_operator NOT NULL DEFAULT '==',
  hook_function text,
  http_hook_id uuid REFERENCES $SCHEMA$.http_hooks(id) ON DELETE SET NULL,
  field_path text,
  expected_value text,
  config jsonb NOT NULL DEFAULT '{}'::jsonb,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT conditions_step_or_transition_xor
    CHECK ((step_id IS NULL) <> (transition_id IS NULL))
);

--SPLIT--

CREATE TABLE $SCHEMA$.enrollments (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  sequence_id uuid NOT NULL REFERENCES $SCHEMA$.sequences(id) ON DELETE CASCADE,
  sequence_version_id uuid NOT NULL REFERENCES $SCHEMA$.sequence_versions(id) ON DELETE RESTRICT,
  tenant_key text,
  subscriber_type text NOT NULL,
  subscriber_id text NOT NULL,
  state $SCHEMA$.enrollment_state NOT NULL DEFAULT 'active',
  current_step_id uuid REFERENCES $SCHEMA$.steps(id) ON DELETE SET NULL,
  adapter_id uuid REFERENCES $SCHEMA$.channel_adapters(id) ON DELETE SET NULL,
  effective_mode text,
  started_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  cancelled_at timestamptz,
  data jsonb NOT NULL DEFAULT '{}'::jsonb,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT enrollments_effective_mode_chk
    CHECK (effective_mode IS NULL OR effective_mode IN ('lifecycle', 'outbound')),
  CONSTRAINT enrollments_outbound_pin_chk
    CHECK (adapter_id IS NULL OR effective_mode = 'outbound')
) WITH (fillfactor = 80, autovacuum_vacuum_scale_factor = 0.05);

--SPLIT--

CREATE TABLE $SCHEMA$.step_executions (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  enrollment_id uuid NOT NULL REFERENCES $SCHEMA$.enrollments(id) ON DELETE CASCADE,
  step_id uuid NOT NULL REFERENCES $SCHEMA$.steps(id) ON DELETE RESTRICT,
  tenant_key text,
  state $SCHEMA$.step_execution_state NOT NULL DEFAULT 'scheduled',
  scheduled_for timestamptz NOT NULL,
  claimed_at timestamptz,
  executed_at timestamptz,
  failed_at timestamptz,
  retry_count integer NOT NULL DEFAULT 0,
  attempt_window integer NOT NULL DEFAULT 0,
  idempotency_key text NOT NULL,
  scheduler_job_id text,
  scheduler_backend text,
  channel text NOT NULL,
  recipient text,
  payload jsonb,
  response jsonb,
  provider_message_id text,
  out_message_id text,
  error_message text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
) WITH (fillfactor = 70, autovacuum_vacuum_scale_factor = 0.02, autovacuum_analyze_scale_factor = 0.01);

--SPLIT--

CREATE TABLE $SCHEMA$.events (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  enrollment_id uuid REFERENCES $SCHEMA$.enrollments(id) ON DELETE SET NULL,
  tenant_key text,
  subscriber_type text,
  subscriber_id text,
  event_type text NOT NULL DEFAULT 'custom',
  event_key text NOT NULL,
  event_data jsonb NOT NULL DEFAULT '{}'::jsonb,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  inserted_at timestamptz NOT NULL DEFAULT now()
);

--SPLIT--

CREATE TABLE $SCHEMA$.suppressions (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_key text,
  channel text NOT NULL,
  recipient text NOT NULL,
  recipient_normalized text NOT NULL,
  reason $SCHEMA$.suppression_reason NOT NULL,
  source text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

--SPLIT--

CREATE TABLE $SCHEMA$.message_events (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  step_execution_id uuid REFERENCES $SCHEMA$.step_executions(id) ON DELETE SET NULL,
  adapter_id uuid REFERENCES $SCHEMA$.channel_adapters(id) ON DELETE SET NULL,
  tenant_key text,
  channel text NOT NULL,
  provider text NOT NULL,
  provider_message_id text,
  provider_event_id text,
  event_type $SCHEMA$.message_event_type NOT NULL,
  event_data jsonb NOT NULL DEFAULT '{}'::jsonb,
  in_reply_to text,
  references_list text[],
  occurred_at timestamptz NOT NULL DEFAULT now(),
  inserted_at timestamptz NOT NULL DEFAULT now()
) WITH (fillfactor = 80, autovacuum_vacuum_scale_factor = 0.05, autovacuum_analyze_scale_factor = 0.02);

--SPLIT--

CREATE TABLE $SCHEMA$.short_links (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  step_execution_id uuid REFERENCES $SCHEMA$.step_executions(id) ON DELETE SET NULL,
  tenant_key text,
  provider text NOT NULL,
  original_url text NOT NULL,
  destination_url text NOT NULL,
  short_url text,
  external_id text,
  idempotency_key text NOT NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
) WITH (fillfactor = 80, autovacuum_vacuum_scale_factor = 0.05);

--SPLIT--

CREATE TABLE $SCHEMA$.adapter_pools (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_key text,
  name text NOT NULL,
  on_pin_unavailable text NOT NULL DEFAULT 'reassign',
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT adapter_pools_tenant_key_nonempty_chk
    CHECK (tenant_key IS NULL OR length(tenant_key) > 0),
  CONSTRAINT adapter_pools_on_pin_unavailable_chk
    CHECK (on_pin_unavailable IN ('pause', 'reassign'))
);

--SPLIT--

CREATE TABLE $SCHEMA$.adapter_pool_members (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  pool_id uuid NOT NULL REFERENCES $SCHEMA$.adapter_pools(id) ON DELETE CASCADE,
  adapter_id uuid NOT NULL REFERENCES $SCHEMA$.channel_adapters(id) ON DELETE CASCADE,
  tenant_key text,
  class text NOT NULL DEFAULT 'mailbox',
  weight integer NOT NULL DEFAULT 1,
  active boolean NOT NULL DEFAULT true,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT adapter_pool_members_tenant_key_nonempty_chk
    CHECK (tenant_key IS NULL OR length(tenant_key) > 0),
  CONSTRAINT adapter_pool_members_class_chk
    CHECK (class IN ('mailbox', 'esp_api')),
  CONSTRAINT adapter_pool_members_weight_positive_chk
    CHECK (weight > 0)
);

--SPLIT--

CREATE TABLE $SCHEMA$.adapter_sequence_budgets (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  adapter_id uuid NOT NULL REFERENCES $SCHEMA$.channel_adapters(id) ON DELETE CASCADE,
  sequence_version_id uuid NOT NULL REFERENCES $SCHEMA$.sequence_versions(id) ON DELETE CASCADE,
  tenant_key text,
  weight integer NOT NULL DEFAULT 1,
  max_share_pct integer NOT NULL DEFAULT 100,
  daily_volume_target integer,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT adapter_sequence_budgets_tenant_key_nonempty_chk
    CHECK (tenant_key IS NULL OR length(tenant_key) > 0),
  CONSTRAINT adapter_sequence_budgets_weight_positive_chk
    CHECK (weight > 0),
  CONSTRAINT adapter_sequence_budgets_max_share_pct_range_chk
    CHECK (max_share_pct BETWEEN 1 AND 100),
  CONSTRAINT adapter_sequence_budgets_daily_volume_target_positive_chk
    CHECK (daily_volume_target IS NULL OR daily_volume_target > 0)
);

--SPLIT--

CREATE UNIQUE INDEX sequences_key_global_idx ON $SCHEMA$.sequences (key) WHERE tenant_key IS NULL;
--SPLIT--
CREATE UNIQUE INDEX sequences_tenant_key_idx ON $SCHEMA$.sequences (tenant_key, key) WHERE tenant_key IS NOT NULL;
--SPLIT--
CREATE UNIQUE INDEX sequence_versions_sequence_version_idx ON $SCHEMA$.sequence_versions (sequence_id, version);
--SPLIT--
CREATE UNIQUE INDEX sequence_versions_one_active_idx ON $SCHEMA$.sequence_versions (sequence_id) WHERE state = 'active';
--SPLIT--
CREATE UNIQUE INDEX steps_version_key_idx ON $SCHEMA$.steps (sequence_version_id, key);
--SPLIT--
CREATE UNIQUE INDEX steps_version_position_idx ON $SCHEMA$.steps (sequence_version_id, position) WHERE position IS NOT NULL;
--SPLIT--
CREATE UNIQUE INDEX channel_adapters_tenant_default_idx ON $SCHEMA$.channel_adapters (channel, tenant_key) WHERE is_default AND tenant_key IS NOT NULL;
--SPLIT--
CREATE UNIQUE INDEX channel_adapters_global_default_idx ON $SCHEMA$.channel_adapters (channel) WHERE is_default AND tenant_key IS NULL;
--SPLIT--
CREATE UNIQUE INDEX http_hooks_sequence_key_idx ON $SCHEMA$.http_hooks (sequence_id, key);
--SPLIT--
CREATE UNIQUE INDEX enrollments_active_subscriber_tenant_idx
  ON $SCHEMA$.enrollments (tenant_key, sequence_id, subscriber_type, subscriber_id)
  WHERE state IN ('active', 'paused') AND tenant_key IS NOT NULL;
--SPLIT--
CREATE UNIQUE INDEX enrollments_active_subscriber_global_idx
  ON $SCHEMA$.enrollments (sequence_id, subscriber_type, subscriber_id)
  WHERE state IN ('active', 'paused') AND tenant_key IS NULL;
--SPLIT--
CREATE UNIQUE INDEX step_executions_idempotency_key_idx ON $SCHEMA$.step_executions (idempotency_key);
--SPLIT--
CREATE UNIQUE INDEX suppressions_tenant_recipient_idx
  ON $SCHEMA$.suppressions (tenant_key, channel, recipient_normalized)
  WHERE tenant_key IS NOT NULL;
--SPLIT--
CREATE UNIQUE INDEX suppressions_global_recipient_idx
  ON $SCHEMA$.suppressions (channel, recipient_normalized)
  WHERE tenant_key IS NULL;
--SPLIT--
CREATE UNIQUE INDEX short_links_idempotency_key_idx ON $SCHEMA$.short_links (idempotency_key);
--SPLIT--
CREATE UNIQUE INDEX message_events_provider_event_idx ON $SCHEMA$.message_events (provider, provider_event_id) WHERE provider_event_id IS NOT NULL;
--SPLIT--
CREATE UNIQUE INDEX adapter_pools_tenant_name_idx
  ON $SCHEMA$.adapter_pools (tenant_key, name)
  WHERE tenant_key IS NOT NULL;
--SPLIT--
CREATE UNIQUE INDEX adapter_pools_global_name_idx
  ON $SCHEMA$.adapter_pools (name)
  WHERE tenant_key IS NULL;
--SPLIT--
CREATE UNIQUE INDEX adapter_pool_members_pool_adapter_idx
  ON $SCHEMA$.adapter_pool_members (pool_id, adapter_id);
--SPLIT--
CREATE UNIQUE INDEX adapter_sequence_budgets_adapter_sequence_idx
  ON $SCHEMA$.adapter_sequence_budgets (adapter_id, sequence_version_id);

--SPLIT--

CREATE INDEX step_executions_due_idx
  ON $SCHEMA$.step_executions (tenant_key, state, scheduled_for)
  WHERE state IN ('scheduled', 'claiming', 'sending');
--SPLIT--
CREATE INDEX step_executions_provider_message_id_idx
  ON $SCHEMA$.step_executions (tenant_key, provider_message_id)
  WHERE provider_message_id IS NOT NULL;
--SPLIT--
CREATE INDEX steps_timing_trigger_event_idx
  ON $SCHEMA$.steps (tenant_key, (timing->>'trigger_event'))
  WHERE timing->>'type' = 'event';
--SPLIT--
CREATE INDEX enrollments_sequence_state_idx ON $SCHEMA$.enrollments (sequence_id, state);
--SPLIT--
CREATE INDEX events_subscriber_lookup_idx ON $SCHEMA$.events (tenant_key, subscriber_type, subscriber_id, event_key, occurred_at);
--SPLIT--
CREATE INDEX sequences_tenant_idx ON $SCHEMA$.sequences (tenant_key);
--SPLIT--
CREATE INDEX sequence_versions_tenant_idx ON $SCHEMA$.sequence_versions (tenant_key);
--SPLIT--
CREATE INDEX steps_tenant_idx ON $SCHEMA$.steps (tenant_key);
--SPLIT--
CREATE INDEX step_transitions_tenant_idx ON $SCHEMA$.step_transitions (tenant_key);
--SPLIT--
CREATE INDEX channel_adapters_tenant_idx ON $SCHEMA$.channel_adapters (tenant_key);
--SPLIT--
CREATE INDEX conditions_tenant_idx ON $SCHEMA$.conditions (tenant_key);
--SPLIT--
CREATE INDEX http_hooks_tenant_idx ON $SCHEMA$.http_hooks (tenant_key);
--SPLIT--
CREATE INDEX enrollments_tenant_idx ON $SCHEMA$.enrollments (tenant_key);
--SPLIT--
CREATE INDEX step_executions_tenant_idx ON $SCHEMA$.step_executions (tenant_key);
--SPLIT--
CREATE INDEX events_tenant_idx ON $SCHEMA$.events (tenant_key);
--SPLIT--
CREATE INDEX suppressions_tenant_idx ON $SCHEMA$.suppressions (tenant_key);
--SPLIT--
CREATE INDEX message_events_tenant_idx ON $SCHEMA$.message_events (tenant_key);
--SPLIT--
CREATE INDEX short_links_tenant_idx ON $SCHEMA$.short_links (tenant_key);
--SPLIT--
CREATE INDEX step_executions_tenant_enrollment_idx ON $SCHEMA$.step_executions (tenant_key, enrollment_id);
--SPLIT--
CREATE INDEX step_executions_tenant_step_idx ON $SCHEMA$.step_executions (tenant_key, step_id);
--SPLIT--
CREATE INDEX step_executions_tenant_adapter_active_idx
  ON $SCHEMA$.step_executions (tenant_key, state, (metadata->>'adapter_id'))
  WHERE state IN ('claiming', 'sending');
--SPLIT--
CREATE INDEX message_events_tenant_step_execution_idx
  ON $SCHEMA$.message_events (tenant_key, step_execution_id)
  WHERE step_execution_id IS NOT NULL;
--SPLIT--
CREATE INDEX events_tenant_enrollment_idx
  ON $SCHEMA$.events (tenant_key, enrollment_id)
  WHERE enrollment_id IS NOT NULL;
--SPLIT--
CREATE INDEX adapter_pool_members_active_pool_idx
  ON $SCHEMA$.adapter_pool_members (pool_id, weight, adapter_id)
  WHERE active = true;
--SPLIT--
CREATE INDEX adapter_pool_members_tenant_pool_idx
  ON $SCHEMA$.adapter_pool_members (tenant_key, pool_id);
--SPLIT--
CREATE INDEX adapter_sequence_budgets_tenant_idx
  ON $SCHEMA$.adapter_sequence_budgets (tenant_key, adapter_id, sequence_version_id);
--SPLIT--
CREATE INDEX enrollments_tenant_adapter_idx
  ON $SCHEMA$.enrollments (tenant_key, adapter_id)
  WHERE adapter_id IS NOT NULL;
--SPLIT--
CREATE INDEX enrollments_tenant_effective_mode_idx
  ON $SCHEMA$.enrollments (tenant_key, effective_mode)
  WHERE effective_mode IS NOT NULL;
--SPLIT--
CREATE UNIQUE INDEX step_executions_out_message_id_idx
  ON $SCHEMA$.step_executions (out_message_id)
  WHERE out_message_id IS NOT NULL;
--SPLIT--
CREATE INDEX message_events_in_reply_to_idx
  ON $SCHEMA$.message_events (in_reply_to)
  WHERE in_reply_to IS NOT NULL;
--SPLIT--
CREATE INDEX message_events_adapter_occurred_idx
  ON $SCHEMA$.message_events (adapter_id, occurred_at)
  WHERE adapter_id IS NOT NULL;

--SPLIT--

CREATE OR REPLACE FUNCTION $SCHEMA$.check_step_execution_state()
RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.state NOT IN ('scheduled', 'cancelled') THEN
      RAISE EXCEPTION 'invalid initial step execution state: %', NEW.state;
    END IF;

    RETURN NEW;
  END IF;

  IF OLD.state = NEW.state THEN
    RETURN NEW;
  END IF;

  IF OLD.state = 'scheduled' AND NEW.state IN ('claiming', 'cancelled') THEN
    RETURN NEW;
  ELSIF OLD.state = 'claiming' AND NEW.state IN ('sending', 'scheduled', 'failed', 'cancelled', 'skipped') THEN
    RETURN NEW;
  ELSIF OLD.state = 'sending' AND NEW.state IN ('sent', 'failed', 'scheduled', 'cancelled') THEN
    RETURN NEW;
  ELSIF OLD.state = 'failed' AND NEW.state IN ('scheduled', 'cancelled') THEN
    RETURN NEW;
  ELSE
    RAISE EXCEPTION 'invalid step execution state transition: % -> %', OLD.state, NEW.state;
  END IF;
END;
$$ LANGUAGE plpgsql;

--SPLIT--

CREATE TRIGGER step_executions_state_fsm
BEFORE INSERT OR UPDATE OF state ON $SCHEMA$.step_executions
FOR EACH ROW EXECUTE FUNCTION $SCHEMA$.check_step_execution_state();

--SPLIT--

CREATE OR REPLACE FUNCTION $SCHEMA$.idempotency_key(
  p_enrollment_id uuid,
  p_step_id uuid,
  p_scheduled_for timestamptz,
  p_attempt integer
) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT encode(
    digest(
      p_enrollment_id::text || ':' ||
      p_step_id::text || ':' ||
      to_char(date_trunc('minute', p_scheduled_for AT TIME ZONE 'UTC'),
              'YYYY-MM-DD"T"HH24:MI:00') || ':' ||
      p_attempt::text,
      'sha256'
    ),
    'hex'
  )
$$;

--SPLIT--

ALTER TABLE $SCHEMA$.sequences ADD CONSTRAINT sequences_tenant_key_nonempty_chk
  CHECK (tenant_key IS NULL OR length(tenant_key) > 0);
--SPLIT--
ALTER TABLE $SCHEMA$.sequence_versions ADD CONSTRAINT sequence_versions_tenant_key_nonempty_chk
  CHECK (tenant_key IS NULL OR length(tenant_key) > 0);
--SPLIT--
ALTER TABLE $SCHEMA$.channel_adapters ADD CONSTRAINT channel_adapters_tenant_key_nonempty_chk
  CHECK (tenant_key IS NULL OR length(tenant_key) > 0);
--SPLIT--
ALTER TABLE $SCHEMA$.steps ADD CONSTRAINT steps_tenant_key_nonempty_chk
  CHECK (tenant_key IS NULL OR length(tenant_key) > 0);
--SPLIT--
ALTER TABLE $SCHEMA$.step_transitions ADD CONSTRAINT step_transitions_tenant_key_nonempty_chk
  CHECK (tenant_key IS NULL OR length(tenant_key) > 0);
--SPLIT--
ALTER TABLE $SCHEMA$.http_hooks ADD CONSTRAINT http_hooks_tenant_key_nonempty_chk
  CHECK (tenant_key IS NULL OR length(tenant_key) > 0);
--SPLIT--
ALTER TABLE $SCHEMA$.conditions ADD CONSTRAINT conditions_tenant_key_nonempty_chk
  CHECK (tenant_key IS NULL OR length(tenant_key) > 0);
--SPLIT--
ALTER TABLE $SCHEMA$.enrollments ADD CONSTRAINT enrollments_tenant_key_nonempty_chk
  CHECK (tenant_key IS NULL OR length(tenant_key) > 0);
--SPLIT--
ALTER TABLE $SCHEMA$.step_executions ADD CONSTRAINT step_executions_tenant_key_nonempty_chk
  CHECK (tenant_key IS NULL OR length(tenant_key) > 0);
--SPLIT--
ALTER TABLE $SCHEMA$.events ADD CONSTRAINT events_tenant_key_nonempty_chk
  CHECK (tenant_key IS NULL OR length(tenant_key) > 0);
--SPLIT--
ALTER TABLE $SCHEMA$.suppressions ADD CONSTRAINT suppressions_tenant_key_nonempty_chk
  CHECK (tenant_key IS NULL OR length(tenant_key) > 0);
--SPLIT--
ALTER TABLE $SCHEMA$.message_events ADD CONSTRAINT message_events_tenant_key_nonempty_chk
  CHECK (tenant_key IS NULL OR length(tenant_key) > 0);
--SPLIT--
ALTER TABLE $SCHEMA$.short_links ADD CONSTRAINT short_links_tenant_key_nonempty_chk
  CHECK (tenant_key IS NULL OR length(tenant_key) > 0);
