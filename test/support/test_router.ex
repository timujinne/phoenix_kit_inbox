defmodule PhoenixKitInbox.Test.Router do
  @moduledoc """
  Minimal Router used by the LiveView test suite. Routes match the URLs
  produced by `PhoenixKitInbox.Paths` so `live/2` calls in tests
  work with exactly the same URLs the LiveViews push themselves to.

  `PhoenixKit.Utils.Routes.path/1` defaults to no URL prefix when the
  `phoenix_kit_settings` table is unavailable. Admin paths for the default
  locale come out prefixless (`/admin/inbox`); tests still mount the
  `/en/admin/inbox` form, so both are routed.
  """

  use Phoenix.Router

  import Phoenix.LiveView.Router

  alias PhoenixKitInbox.Test.InboxRoutes

  require InboxRoutes

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {PhoenixKitInbox.Test.Layouts, :root})
    plug(:protect_from_forgery)
  end

  # Stands in for core's admin pipeline: the scope comes from the test
  # session (`LiveCase.put_test_scope/2`).
  pipeline :phoenix_kit_admin_only do
    plug(:assign_test_scope)
  end

  InboxRoutes.routes()

  live_session :inbox_test,
    layout: {PhoenixKitInbox.Test.Layouts, :app},
    on_mount: {PhoenixKitInbox.Test.Hooks, :assign_scope} do
    # Core emits admin paths without the default locale (2.5x+), and its
    # router keeps both shapes reachable; mirror both so a `push_patch` built
    # by `Paths` lands on a route whichever shape it takes.
    for base <- ["/en/admin/inbox", "/admin/inbox"] do
      scope base, PhoenixKitInbox.Web do
        pipe_through(:browser)

        live("/", InboxLive, :index)
        live("/compose", ComposeLive, :new)
        live("/mailboxes", MailboxesLive, :index)
        live("/settings", SettingsLive, :index)
      end
    end
  end

  # The user-menu page core generates from `user_dashboard_tabs/0`, outside
  # the admin area. It draws core's layout itself, so no test layout here.
  live_session :inbox_user_test,
    layout: false,
    on_mount: {PhoenixKitInbox.Test.Hooks, :assign_scope} do
    for base <- ["/en/dashboard", "/dashboard"] do
      scope base, PhoenixKitInbox.Web do
        pipe_through(:browser)

        live("/inbox-settings", MySettingsLive, :index)
      end
    end
  end

  @doc false
  def assign_test_scope(conn, _opts) do
    case get_session(conn, "phoenix_kit_test_scope") do
      nil -> conn
      scope -> assign(conn, :phoenix_kit_current_scope, scope)
    end
  end
end
