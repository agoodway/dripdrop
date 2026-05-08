## ADDED Requirements

### Requirement: Spintax Rendering Layer Composes With Existing Template Engines

The system SHALL provide an optional `DripDrop.Templates.Spintax` rendering layer that runs after the foundation's Liquex/EEx/MJML rendering and before the channel adapter delivers. The layer SHALL parse spintax syntax (`{option_a|option_b|option_c}`) and pick exactly one option per spin token using a deterministic seed. Nested spintax (`{{a|b} c|d}`) SHALL be supported with right-to-left evaluation. The layer SHALL be off by default and opt-in per step via `step.config["template_variation"]["spintax"] == true`.

#### Scenario: Spintax expands deterministically per execution
- **WHEN** a step's rendered output is `"{Hi|Hello|Hey} {{first_name}}, {welcome|thanks for joining}!"` and `step.config["template_variation"]["spintax"] == true`
- **THEN** for a given `step_execution_id` and `attempt_window`, the spintax layer produces a stable output (e.g., `"Hello Sam, thanks for joining!"`) on every retry of that execution.

#### Scenario: Spintax off by default
- **WHEN** a step has `template_variation` unset
- **THEN** the spintax layer is bypassed and the rendered output (which may incidentally contain `{...|...}` syntax that operators want sent literally) passes through unmodified.

#### Scenario: Nested spintax resolves inside-out
- **WHEN** the rendered output contains `"{{Hi|Hello} there|Hey friend}"`
- **THEN** the inner `{Hi|Hello}` resolves first (yielding e.g., `"Hello"`), then the outer `{Hello there|Hey friend}` resolves (yielding e.g., `"Hello there"` or `"Hey friend"`).

### Requirement: Spintax Seed Is Deterministic Per Execution For Idempotent Retries

The system SHALL derive the spintax PRNG seed from `(step_execution_id, attempt_window)` so that retries of the same execution produce byte-identical output. Replays via `DripDrop.replay/1` (which bumps `attempt_window`) SHALL produce different output, matching the foundation's idempotency semantics. The seed derivation SHALL NOT use wall-clock time, system entropy, or any other non-deterministic input.

#### Scenario: Retry produces identical spintax output
- **WHEN** a step execution renders with spintax enabled, fails on a transient provider error, and retries with the same `step_execution_id` and `attempt_window`
- **THEN** the retry's spintax output is byte-identical to the original attempt; the recipient sees only one variation regardless of how many retries occurred (provider idempotency suppresses duplicate sends).

#### Scenario: Replay produces different output
- **WHEN** an operator calls `DripDrop.replay/1` against a failed execution, which bumps `attempt_window`
- **THEN** the replay's spintax seed differs (because `attempt_window` changed), and the spintax output may differ from the original attempt — matching the operator-visible "fresh attempt" semantics of replay.

### Requirement: Spintax Failures Degrade Gracefully

When the spintax parser encounters malformed syntax (unbalanced braces, empty alternatives, etc.), the system SHALL emit `[:dripdrop, :template, :spintax_error]` telemetry with the offending span and SHALL pass the original (un-spun) text through to the channel adapter. This preserves operator-authored content in the face of typos rather than failing the dispatch outright. Scope of "malformed" is documented in the spintax syntax guide.

#### Scenario: Unbalanced braces fall back to original
- **WHEN** the rendered output contains `"{Hi|Hello"` (missing closing brace)
- **THEN** spintax emits `[:dripdrop, :template, :spintax_error]` with `reason: :unbalanced_braces`, leaves the literal `"{Hi|Hello"` in the output, and dispatch proceeds with that text.

#### Scenario: Empty alternative skipped
- **WHEN** the rendered output contains `"{Hi||Hello}"` (an empty alternative between pipes)
- **THEN** the empty option is filtered out (treated as if it weren't there), spintax picks between `"Hi"` and `"Hello"`, and `[:dripdrop, :template, :spintax_warning]` may fire for operator visibility.
