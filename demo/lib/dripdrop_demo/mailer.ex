defmodule DripdropDemo.Mailer do
  @moduledoc """
  Swoosh mailer for Phoenix-owned demo emails.
  """

  use Swoosh.Mailer, otp_app: :dripdrop_demo
end
