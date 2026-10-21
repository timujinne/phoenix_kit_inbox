defmodule PhoenixKitInbox.UserMenuTest do
  @moduledoc """
  The avatar-menu entries (`user_dashboard_tabs/0`): "Mail" opens the inbox
  in the admin area, "Mail settings" is the user's own settings page — both
  only for users who can use Inbox.
  """

  use PhoenixKitInbox.DataCase, async: false

  alias PhoenixKit.Dashboard.Tab

  setup do
    %{tabs: PhoenixKitInbox.user_dashboard_tabs()}
  end

  defp tab(tabs, id), do: Enum.find(tabs, &(&1.id == id))

  test "\"Mail\" points at the inbox itself, with no route of its own", %{tabs: tabs} do
    mail = tab(tabs, :inbox_user_mail)

    assert mail.icon == "hero-envelope"
    assert mail.live_view == nil
    # An absolute path is left as it is by core, so the link leaves /dashboard.
    assert Tab.resolve_path(mail, :user_dashboard).path == "/admin/inbox"
  end

  test "\"Mail settings\" is a personal page core routes under /dashboard", %{tabs: tabs} do
    settings = tab(tabs, :inbox_user_settings)

    assert settings.icon == "hero-cog-6-tooth"
    assert settings.personal == true
    assert settings.live_view == {PhoenixKitInbox.Web.MySettingsLive, :index}
    assert Tab.resolve_path(settings, :user_dashboard).path == "/dashboard/inbox-settings"
  end

  test "both are in the avatar menu only for users who can use Inbox", %{tabs: tabs} do
    enable_inbox!()
    member = scope_for(user_fixture())
    client = scope_for(user_fixture(%{inbox_member: false}), [])

    for id <- [:inbox_user_mail, :inbox_user_settings] do
      assert Tab.user_menu?(tab(tabs, id), member)
      refute Tab.user_menu?(tab(tabs, id), client)
      refute Tab.user_menu?(tab(tabs, id), nil)
    end
  end

  test "both are in the sidebar only for users who can use Inbox", %{tabs: tabs} do
    enable_inbox!()
    member = scope_for(user_fixture())
    client = scope_for(user_fixture(%{inbox_member: false}), [])

    for id <- [:inbox_user_mail, :inbox_user_settings] do
      assert Tab.permission_granted?(tab(tabs, id), member)
      refute Tab.permission_granted?(tab(tabs, id), client)
    end
  end

  test "nobody gets them while the module is off", %{tabs: tabs} do
    PhoenixKitInbox.disable_system()
    member = scope_for(user_fixture())

    refute Tab.user_menu?(tab(tabs, :inbox_user_mail), member)
    refute Tab.user_menu?(tab(tabs, :inbox_user_settings), member)
  end
end
