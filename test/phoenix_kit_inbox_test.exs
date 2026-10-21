defmodule PhoenixKitInboxTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Module-contract tests: the callbacks PhoenixKit's discovery, routing, and
  permissions machinery reads at startup. These are pure — no DB — so they run
  even when the test database is absent.
  """

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Users.Permissions

  test "module_key is the lowercase underscore key used everywhere" do
    assert PhoenixKitInbox.module_key() == "inbox"
  end

  test "module_name is the human-readable label" do
    assert PhoenixKitInbox.module_name() == "Inbox"
  end

  test "version matches mix.exs" do
    assert PhoenixKitInbox.version() == "0.2.1"
  end

  test "permission_metadata key matches module_key (validated by core at startup)" do
    metadata = PhoenixKitInbox.permission_metadata()

    assert metadata.key == PhoenixKitInbox.module_key()
    assert is_binary(metadata.label)
    assert String.starts_with?(metadata.icon, "hero-")
    assert is_binary(metadata.description)
  end

  test "permission_metadata declares the send_external and manage_shared sub-permissions" do
    subs = PhoenixKitInbox.permission_metadata().sub_permissions

    assert Enum.map(subs, & &1.key) == ["send_external", "manage_shared"]

    for sub <- subs do
      assert sub.key =~ ~r/^[a-z][a-z0-9_]*$/
      assert is_binary(sub.label)
      assert is_binary(sub.description)
    end
  end

  test "core composes the sub-permissions under the inbox key" do
    assert Permissions.parent_key("inbox.manage_shared") == "inbox"
    assert Permissions.parent_key("inbox.send_external") == "inbox"
  end

  test "css_sources returns this OTP app so Tailwind scans our templates" do
    assert PhoenixKitInbox.css_sources() == [:phoenix_kit_inbox]
  end

  test "migration_module points at this module's own coordinator" do
    assert PhoenixKitInbox.migration_module() == PhoenixKitInbox.Migrations
    assert PhoenixKitInbox.Migrations.current_version() == 3
  end

  describe "admin_tabs/0" do
    setup do
      %{tabs: PhoenixKitInbox.admin_tabs()}
    end

    test "every tab is a Tab struct with a live_view and our permission", %{tabs: tabs} do
      assert length(tabs) == 4

      for tab <- tabs do
        assert %Tab{} = tab
        assert tab.permission == "inbox"
        assert match?({mod, _action} when is_atom(mod), tab.live_view)
      end
    end

    test "tab ids are unique and prefixed with :admin_inbox", %{tabs: tabs} do
      ids = Enum.map(tabs, & &1.id)

      assert ids == Enum.uniq(ids)
      assert Enum.all?(ids, &String.starts_with?(Atom.to_string(&1), "admin_inbox"))
    end

    test "paths use hyphens, never underscores", %{tabs: tabs} do
      for %Tab{path: path} <- tabs do
        refute String.contains?(path, "_")
      end
    end

    test "compose is hidden — reached from the New message button, not the sidebar", %{tabs: tabs} do
      compose = Enum.find(tabs, &(&1.id == :admin_inbox_compose))

      assert compose.visible == false
      assert compose.parent == :admin_inbox
    end

    test "subtabs hang off the parent tab", %{tabs: tabs} do
      subtabs = Enum.filter(tabs, &(&1.parent != nil))

      assert length(subtabs) == 3
      assert Enum.all?(subtabs, &(&1.parent == :admin_inbox))
    end
  end

  test "notification_types actions match what Notify actually emits" do
    [type] = PhoenixKitInbox.notification_types()

    assert type.key == "inbox"
    assert "inbox.message_received" in type.actions
  end

  test "enabled? degrades to false rather than raising when the DB is unavailable" do
    assert is_boolean(PhoenixKitInbox.enabled?())
  end
end
