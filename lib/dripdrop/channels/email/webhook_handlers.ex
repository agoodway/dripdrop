defmodule DripDrop.Channels.Email.Mailgun.WebhookHandler do
  @moduledoc """
  Marker module for Mailgun webhook route dispatch.
  """
end

defmodule DripDrop.Channels.Email.SendGrid.WebhookHandler do
  @moduledoc """
  Marker module for SendGrid Event Webhook route dispatch.
  """
end

defmodule DripDrop.Channels.Email.Postmark.WebhookHandler do
  @moduledoc """
  Marker module for Postmark webhook route dispatch.
  """
end

defmodule DripDrop.Channels.Email.MailerSend.WebhookHandler do
  @moduledoc """
  Marker module for MailerSend webhook route dispatch.
  """
end

defmodule DripDrop.Channels.Email.SES.WebhookHandler do
  @moduledoc """
  Marker module for Amazon SES SNS webhook route dispatch.
  """
end
