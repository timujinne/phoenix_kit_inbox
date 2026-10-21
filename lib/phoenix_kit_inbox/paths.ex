defmodule PhoenixKitInbox.Paths do
  @moduledoc """
  Centralized URL paths for the Inbox module.

  Every `href`, `patch`, `navigate`, and `redirect` in this module goes through
  a function here, and every function here goes through
  `PhoenixKit.Utils.Routes.path/1` so the host's URL prefix and the current
  locale are applied. A hardcoded `"/admin/inbox"` works on a default install
  and 404s on a prefixed or localized one.
  """

  alias PhoenixKit.Utils.Routes

  @base "/admin/inbox"
  @my_settings "/dashboard/inbox-settings"

  @doc """
  The mailbox view.

  ## Options

    * `:mailbox` — mailbox uuid to open (defaults to the user's personal one)
    * `:folder` — one of `PhoenixKitInbox.Schemas.Delivery.folders/0`
    * `:message` — message uuid to open in the reading pane
    * `:search` — search term to filter the list by
    * `:unseen` — `"1"` to show only unseen messages
    * `:page` — 1-based page number; page 1 is omitted so the canonical
      first-page URL has no `page=` in it

  Everything except the mailbox itself is a query param rather than a path
  segment, so the whole mailbox stays one LiveView: switching folders or
  opening a message is a `push_patch`, not a remount. `InboxLive` builds every
  one of its patches through this function.

      iex> PhoenixKitInbox.Paths.inbox(folder: "sent")
      "/admin/inbox?folder=sent"
  """
  @spec inbox(keyword()) :: String.t()
  def inbox(opts \\ []) do
    query =
      [
        mailbox: opts[:mailbox],
        folder: opts[:folder],
        message: opts[:message],
        search: opts[:search],
        unseen: opts[:unseen],
        page: page_param(opts[:page])
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)

    case query do
      [] -> Routes.path(@base)
      params -> Routes.path(@base <> "?" <> URI.encode_query(params))
    end
  end

  defp page_param(page) when page in [nil, 1, "1"], do: nil
  defp page_param(page), do: page

  @doc "The compose view. Pass `:reply_to` or `:draft` to prefill it."
  @spec compose(keyword()) :: String.t()
  def compose(opts \\ []) do
    query =
      [
        mailbox: opts[:mailbox],
        reply_to: opts[:reply_to],
        forward: opts[:forward],
        draft: opts[:draft]
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)

    case query do
      [] -> Routes.path(@base <> "/compose")
      params -> Routes.path(@base <> "/compose?" <> URI.encode_query(params))
    end
  end

  @doc "The shared-mailbox management view."
  @spec mailboxes() :: String.t()
  def mailboxes, do: Routes.path(@base <> "/mailboxes")

  @doc """
  The mail page of core's Settings section: shared senders and
  shared-mailbox signatures.
  """
  @spec settings() :: String.t()
  def settings, do: Routes.path("/admin/settings/inbox")

  @doc """
  The user's own mail settings — a user-menu page (`user_dashboard_tabs/0`),
  outside the admin area: signatures, default Reply-To, personal senders.
  """
  @spec my_settings() :: String.t()
  def my_settings, do: Routes.path(@my_settings)

  @doc "Where core's personal integrations page lives (a personal sender's connection)."
  @spec my_integrations() :: String.t()
  def my_integrations, do: Routes.path("/profile/settings/integrations")

  @doc """
  The download of an attachment (`PhoenixKitInbox.Web.AttachmentController`).
  A controller route, so it carries no locale segment.

      iex> PhoenixKitInbox.Paths.attachment("0190…")
      "/admin/inbox/files/0190…"
  """
  @spec attachment(binary()) :: String.t()
  def attachment(attachment_uuid),
    do: Routes.path(@base <> "/files/" <> attachment_uuid, locale: :none)

  @doc """
  The **raw** (unprefixed) path to a message, for embedding in notification
  links.

  `PhoenixKit.Notifications` runs stored links through `Routes.path/1` itself,
  so a pre-prefixed path would come out double-prefixed.
  """
  @spec raw_message_path(binary(), binary()) :: String.t()
  def raw_message_path(mailbox_uuid, message_uuid) do
    @base <> "?" <> URI.encode_query(mailbox: mailbox_uuid, message: message_uuid)
  end
end
