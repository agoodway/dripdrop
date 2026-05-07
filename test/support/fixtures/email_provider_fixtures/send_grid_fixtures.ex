defmodule DripDrop.EmailProviderFixtures.SendGridFixtures do
  @moduledoc """
  Real-shape fixtures for the SendGrid v3 Mail Send API (`POST /v3/mail/send`).

  Source: https://www.twilio.com/docs/sendgrid/api-reference/mail-send/mail-send
  Pulled: 2026-05-07.

  These fixtures mirror the wire-level shapes a SendGrid client must build
  (request body) and consume (response body / headers / errors). They are
  used by the SendGrid adapter integration tests to ground assertions against
  the documented v3 contract instead of an ad-hoc invented schema.

  ## Wire-level reference

  ### Request — `POST https://api.sendgrid.com/v3/mail/send`

  Top-level fields:

    * `personalizations` (array, required) — recipients, per-recipient subject,
      `headers`, `substitutions`, `dynamic_template_data`, `custom_args`,
      `send_at`, `cc`, `bcc`.
    * `from` (object, required) — `{email, name}`.
    * `reply_to` (object) — `{email, name}`.
    * `subject` (string) — used when no per-personalization subject is set.
    * `content` (array) — `[{type, value}]`, e.g. `text/plain`, `text/html`.
    * `template_id` (string) — Dynamic Templates start with `d-`.
    * `categories` (array of strings, max 10).
    * `custom_args` (object) — message-level tags forwarded on event webhooks.
    * `send_at` (integer) — Unix timestamp for scheduled delivery.
    * `attachments` (array of `{content, type, filename, disposition, content_id}`).
    * `headers` (object).
    * `tracking_settings` (object) — `click_tracking`, `open_tracking`,
      `subscription_tracking`, `ganalytics`.
    * `mail_settings`, `asm`, `batch_id`, `ip_pool_name`, `sections`.

  ### Response

    * Success: HTTP `202 Accepted` with an empty body and an `X-Message-Id`
      response header (Swoosh exposes the response as `%{}`).
    * Error: HTTP `4xx`/`5xx` with body
      `%{"errors" => [%{"message" => ..., "field" => ..., "help" => ...}]}`.
  """

  @doc """
  Minimal valid `mail/send` request body — single recipient, plaintext + HTML.
  """
  @spec basic_request() :: map()
  def basic_request do
    %{
      "personalizations" => [
        %{
          "to" => [%{"email" => "ada@example.com", "name" => "Ada"}],
          "subject" => "Welcome"
        }
      ],
      "from" => %{"email" => "team@example.com", "name" => "DripDrop"},
      "reply_to" => %{"email" => "support@example.com", "name" => "DripDrop Support"},
      "content" => [
        %{"type" => "text/plain", "value" => "Hello Ada"},
        %{"type" => "text/html", "value" => "<p>Hello Ada</p>"}
      ],
      "headers" => %{
        "X-DripDrop-Idempotency-Key" => "idem-001"
      }
    }
  end

  @doc """
  Dynamic Template request — uses `template_id` (the `d-...` form) plus
  per-personalization `dynamic_template_data`.
  """
  @spec dynamic_template_request() :: map()
  def dynamic_template_request do
    %{
      "personalizations" => [
        %{
          "to" => [%{"email" => "ada@example.com"}],
          "dynamic_template_data" => %{
            "first_name" => "Ada",
            "order_id" => "ORD-12345",
            "items" => [
              %{"sku" => "SKU-1", "qty" => 2},
              %{"sku" => "SKU-2", "qty" => 1}
            ]
          },
          "custom_args" => %{
            "step_id" => "welcome-1",
            "tenant_key" => "tenant-a"
          }
        }
      ],
      "from" => %{"email" => "team@example.com", "name" => "DripDrop"},
      "template_id" => "d-1234567890abcdef1234567890abcdef"
    }
  end

  @doc """
  Categorized + tracked send — exercises body-level `categories`,
  `custom_args`, `send_at`, and `tracking_settings`.
  """
  @spec categorized_request() :: map()
  def categorized_request do
    %{
      "personalizations" => [
        %{
          "to" => [%{"email" => "ada@example.com"}],
          "subject" => "Your weekly digest"
        }
      ],
      "from" => %{"email" => "team@example.com", "name" => "DripDrop"},
      "subject" => "Your weekly digest",
      "content" => [
        %{"type" => "text/plain", "value" => "Digest body"}
      ],
      "categories" => ["digest", "weekly", "tenant-a"],
      "custom_args" => %{
        "campaign_id" => "weekly-2026-19",
        "sequence_key" => "weekly-digest"
      },
      "send_at" => 1_762_473_600,
      "tracking_settings" => %{
        "click_tracking" => %{"enable" => true, "enable_text" => false},
        "open_tracking" => %{"enable" => true, "substitution_tag" => "%open-track%"}
      }
    }
  end

  @doc """
  Successful `202 Accepted` response shape returned by SendGrid.

  Body is intentionally empty; the message id is delivered via the
  `X-Message-Id` response header.
  """
  @spec success_response() :: map()
  def success_response do
    %{
      status: 202,
      headers: %{
        "x-message-id" => "abc123.filterdrecv-9d8f6c5b4a-xyz12-1-12345-67",
        "content-length" => "0"
      },
      body: ""
    }
  end

  @doc """
  Documented error envelope returned for 4xx responses.
  """
  @spec error_response() :: map()
  def error_response do
    %{
      status: 400,
      headers: %{"content-type" => "application/json"},
      body: %{
        "errors" => [
          %{
            "message" => "The from email does not contain a valid address.",
            "field" => "from.email",
            "help" =>
              "http://sendgrid.com/docs/API_Reference/Web_API_v3/Mail/errors.html#message.from"
          }
        ]
      }
    }
  end
end
