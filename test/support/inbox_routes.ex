defmodule PhoenixKitInbox.Test.InboxRoutes do
  @moduledoc """
  Mounts the routes `PhoenixKitInbox.Web.Routes.generate/1` hands a host
  router, so the test router serves exactly what a host's does.
  """

  alias PhoenixKitInbox.Web.Routes

  defmacro routes, do: Routes.generate("/")
end
