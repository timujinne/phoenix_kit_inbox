defmodule PhoenixKitInbox.Outbound.Mailer do
  @moduledoc """
  The production transport of `PhoenixKitInbox.Outbound`: core's
  `PhoenixKit.Mailer.deliver_via_integration/3`, with the options
  `Outbound.deliver/2` built.
  """

  @behaviour PhoenixKitInbox.Outbound

  @impl true
  def deliver_via_integration(email, integration_uuid, opts),
    do: PhoenixKit.Mailer.deliver_via_integration(email, integration_uuid, opts)
end
