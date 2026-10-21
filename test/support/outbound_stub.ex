defmodule PhoenixKitInbox.Test.Outbound do
  @moduledoc """
  The transport behind `PhoenixKitInbox.Outbound` in tests
  (`config :phoenix_kit_inbox, :outbound`): records every call by sending
  `{:outbound, email, integration_uuid, opts}` to the test process and
  answers what the test asked for. Nothing leaves the machine.

  Set up with `PhoenixKitInbox.DataCase.outbound_setup/1`; the answer is
  `{:ok, %{id: "stub"}}` unless `outbound_result/1` changed it.
  """

  @behaviour PhoenixKitInbox.Outbound

  @impl true
  def deliver_via_integration(email, integration_uuid, opts) do
    config = Application.get_env(:phoenix_kit_inbox, :test_outbound, %{})

    if pid = config[:pid], do: send(pid, {:outbound, email, integration_uuid, opts})

    case Map.get(config, :result, {:ok, %{id: "stub"}}) do
      fun when is_function(fun, 3) -> fun.(email, integration_uuid, opts)
      result -> result
    end
  end
end
