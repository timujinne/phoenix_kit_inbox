defmodule PhoenixKit.Modules.Emails do
  @moduledoc """
  Stands in for `phoenix_kit_emails` in tests — Inbox treats that package as
  optional and only asks it `enabled?/0`. Off unless a test turns it on with
  `PhoenixKitInbox.DataCase.emails_module_enabled!/0`.
  """

  def enabled?, do: Application.get_env(:phoenix_kit_inbox, :test_emails_enabled, false)
end
