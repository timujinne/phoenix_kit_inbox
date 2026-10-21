defmodule PhoenixKitInbox.Web.Routes do
  @moduledoc """
  The module's non-LiveView routes, handed to the host router through
  `PhoenixKitInbox.route_module/0`.

  Core inserts a route module's routes as they are — public — so the
  pipeline is set here: `:browser` and core's `:phoenix_kit_admin_only`, as
  `phoenix_kit_emails` does for its export. The download controller checks
  the module, the `"inbox"` permission and the viewer's place on the message
  itself.

  The path follows the configured admin segment (`PhoenixKit.Config.get_admin_path/0`),
  which core applies to its own route table but not to a route module's, so
  `PhoenixKitInbox.Paths.attachment/1` and this route stay in step.
  """

  @doc "Routes for the host router, under `url_prefix`."
  def generate(url_prefix) do
    controller = PhoenixKitInbox.Web.AttachmentController
    path = PhoenixKit.Config.get_admin_path() <> "/inbox/files/:attachment_uuid"

    quote do
      scope unquote(url_prefix) do
        pipe_through([:browser, :phoenix_kit_admin_only])

        get(unquote(path), unquote(controller), :show, as: :phoenix_kit_inbox_attachment)
      end
    end
  end
end
