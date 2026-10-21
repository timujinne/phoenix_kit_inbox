defmodule PhoenixKitInbox.Gettext do
  @moduledoc """
  Gettext backend for `phoenix_kit_inbox`.

  Owns the catalogues under `priv/gettext/` (`en`, `et`, `ru`). The locale is
  not set here: core installs it for the request on every backend's behalf
  (see `PhoenixKitWeb.Users.Auth.put_gettext_locale/2`), and a backend with no
  locale of its own reads the process-wide one.
  """
  use Gettext.Backend, otp_app: :phoenix_kit_inbox
end
