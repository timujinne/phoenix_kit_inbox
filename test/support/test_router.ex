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

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {PhoenixKitInbox.Test.Layouts, :root})
    plug(:protect_from_forgery)
  end

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
      end
    end
  end
end
