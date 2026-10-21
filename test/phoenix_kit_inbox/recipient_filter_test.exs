defmodule PhoenixKitInbox.RecipientFilterTest do
  @moduledoc """
  The host's `config :phoenix_kit_inbox, recipient_filter: {Mod, :fun}`
  replaces the default circle rule. Global application env, hence not async.
  """

  use PhoenixKitInbox.DataCase, async: false

  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Members

  defmodule Filter do
    @moduledoc false
    def only_ok(%{username: "ok" <> _}), do: true
    def only_ok(_), do: false

    def broken(_), do: raise("filter blew up")
  end

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit_inbox, :recipient_filter) end)
  end

  test "the host filter decides instead of the role rule" do
    Application.put_env(:phoenix_kit_inbox, :recipient_filter, {Filter, :only_ok})

    outsider =
      user_fixture(%{username: "ok_guest", email: "ok_guest@example.com", inbox_member: false})

    member = user_fixture(%{username: "no_staff", email: "no_staff@example.com"})

    assert Members.member?(outsider)
    refute Members.member?(member)

    assert {:ok, %{owner_uuid: owner}} = Mailboxes.fetch_mailbox_by_recipient("@ok_guest")
    assert owner == outsider.uuid
    assert {:error, :recipient_not_found} = Mailboxes.fetch_mailbox_by_recipient("@no_staff")

    handles = user_fixture().uuid |> Mailboxes.search_recipients("_") |> Enum.map(& &1.handle)
    assert "@ok_guest" in handles
    refute "@no_staff" in handles
  end

  test "a filter that raises shuts the user out rather than letting them in" do
    Application.put_env(:phoenix_kit_inbox, :recipient_filter, {Filter, :broken})
    user = user_fixture(%{username: "anyone", email: "anyone@example.com"})

    refute Members.member?(user)
    assert {:error, :recipient_not_found} = Mailboxes.fetch_mailbox_by_recipient("@anyone")
  end
end
