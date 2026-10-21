defmodule PhoenixKitInbox do
  @moduledoc """
  Internal mailbox for PhoenixKit — an in-app email client for messages between
  the users of your application.

  The UI is the familiar three-pane webmail layout (folders, message list,
  reading pane) and the data model is the familiar one too: a message is stored
  once and delivered as one row per recipient mailbox, so read/starred/foldered
  state is per-person.

  ## What it is, and isn't

  Inbox is **internal**. Messages are addressed to mailboxes inside this
  application; nothing is fetched over IMAP and nothing is relayed to the
  outside world. What it *can* do, when the host also runs
  `phoenix_kit_emails`, is send a short "you have a new message" nudge to a
  recipient's real email address — a soft, `Code.ensure_loaded?/1`-guarded
  integration with no dependency in `mix.exs`, off by default behind the
  `inbox_email_nudges_enabled` setting. See `PhoenixKitInbox.Notify`.

  If you want outbound campaign email, that's `phoenix_kit_newsletters`; for
  delivery tracking and SES integration, `phoenix_kit_emails`; for customer
  ticketing, `phoenix_kit_customer_support`. Inbox is the messages your users
  send each other.

  ## Mailboxes

  Every user gets one **personal** mailbox, created lazily on first visit.
  Admins can also create **shared** mailboxes (`support`, `sales`, …) and grant
  other users `read` / `write` / `admin` access to them — the same
  own-it-or-be-granted-it model `phoenix_kit_calendar` uses for calendars. The
  module-level `"inbox"` permission decides who can open Inbox at all; grants
  decide which mailboxes they see inside it.

  ## Database

  Unlike older PhoenixKit modules, Inbox **owns its migrations**. Tables are
  created by `PhoenixKitInbox.Migrations` (returned from `migration_module/0`)
  and applied by `mix phoenix_kit.update`, not by a versioned migration in core.
  Nothing has to be released in `phoenix_kit` for this module's schema to
  change.

  ## Installation

      # mix.exs
      {:phoenix_kit_inbox, "~> 0.2"}

  Then `mix deps.get` and `mix phoenix_kit.update`. PhoenixKit auto-discovers
  the module at startup — the tab appears in the admin sidebar and the Modules
  page with no config.
  """

  use PhoenixKit.Module

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope

  @settings_key "inbox_enabled"
  @nudges_settings_key "inbox_email_nudges_enabled"

  # ===========================================================================
  # Required callbacks
  # ===========================================================================

  @impl PhoenixKit.Module
  @doc "Unique key for this module. Used in settings, permissions, and PubSub events."
  def module_key, do: "inbox"

  @impl PhoenixKit.Module
  @doc "Display name shown in the admin UI."
  def module_name, do: "Inbox"

  @impl PhoenixKit.Module
  @doc """
  Whether the module is currently enabled.

  Defensive on purpose: `enabled?/0` is called during startup and route
  compilation, before the DB is guaranteed to be up. Every failure mode
  (missing table, dead pool, sandbox owner gone) returns `false` so callers
  never have to special-case boot ordering.
  """
  def enabled? do
    Settings.get_boolean_setting(@settings_key, false)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @impl PhoenixKit.Module
  @doc "Enables the module."
  def enable_system do
    Settings.update_boolean_setting_with_module(@settings_key, true, module_key())
  end

  @impl PhoenixKit.Module
  @doc "Disables the module."
  def disable_system do
    Settings.update_boolean_setting_with_module(@settings_key, false, module_key())
  end

  # ===========================================================================
  # Optional callbacks
  # ===========================================================================

  @impl PhoenixKit.Module
  @doc "Version string. Shown on the admin Modules page."
  def version, do: "0.2.1"

  @impl PhoenixKit.Module
  @doc """
  Module-owned versioned migrations.

  This is the callback that keeps Inbox's DDL out of core. `mix
  phoenix_kit.update` reads it, compares the installed version against
  `PhoenixKitInbox.Migrations.current_version/0`, and generates a host
  migration when behind.
  """
  def migration_module, do: PhoenixKitInbox.Migrations

  @impl PhoenixKit.Module
  @doc """
  Permission metadata for the roles/permissions matrix.

  The `:key` MUST match `module_key/0` — PhoenixKit validates this at startup.

  The base `"inbox"` key opens Inbox: reading and writing internal mail from
  the user's own mailbox and the mailboxes they hold a grant on. Two
  sub-permissions, stored by core as `"inbox.<key>"` and checked by this
  module with `PhoenixKit.Users.Auth.Scope.can?/2`, add capabilities on top:

    * `inbox.send_external` — write to addresses outside the application
    * `inbox.manage_shared` — create shared mailboxes and set their addresses
  """
  def permission_metadata do
    %{
      key: module_key(),
      label: "Inbox",
      icon: "hero-inbox-arrow-down",
      description: "Internal mailboxes — send and receive messages between users",
      sub_permissions: [
        %{
          key: "send_external",
          label: "Send to external addresses",
          description: "Write to email addresses outside this application"
        },
        %{
          key: "manage_shared",
          label: "Manage shared mailboxes",
          description: "Create shared mailboxes and set their addresses"
        }
      ]
    }
  end

  @impl PhoenixKit.Module
  @doc """
  Admin sidebar tabs.

  Four visible pages plus one hidden route for the compose view. Settings
  (shared senders, shared-mailbox signatures) is shown only to holders of
  `inbox.manage_shared`; the page checks it again. Folder
  navigation is **not** a tab per folder — the mailbox is a single LiveView and
  folders are query params, so switching folders is a `push_patch` rather than
  a remount (see `PhoenixKitInbox.Paths.inbox/1`).
  """
  def admin_tabs do
    [
      %Tab{
        id: :admin_inbox,
        label: "Inbox",
        icon: "hero-inbox-arrow-down",
        path: "inbox",
        priority: 645,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        live_view: {PhoenixKitInbox.Web.InboxLive, :index}
      },
      %Tab{
        id: :admin_inbox_messages,
        label: "Messages",
        icon: "hero-envelope",
        path: "inbox",
        priority: 646,
        level: :admin,
        permission: module_key(),
        match: :exact,
        parent: :admin_inbox,
        live_view: {PhoenixKitInbox.Web.InboxLive, :index}
      },
      # Hidden: reachable from the "New message" button, not the sidebar.
      %Tab{
        id: :admin_inbox_compose,
        label: "Compose",
        icon: "hero-pencil-square",
        path: "inbox/compose",
        priority: 647,
        level: :admin,
        permission: module_key(),
        parent: :admin_inbox,
        visible: false,
        live_view: {PhoenixKitInbox.Web.ComposeLive, :new}
      },
      %Tab{
        id: :admin_inbox_mailboxes,
        label: "Mailboxes",
        icon: "hero-user-group",
        path: "inbox/mailboxes",
        priority: 648,
        level: :admin,
        permission: module_key(),
        parent: :admin_inbox,
        live_view: {PhoenixKitInbox.Web.MailboxesLive, :index}
      },
      %Tab{
        id: :admin_inbox_settings,
        label: "Settings",
        icon: "hero-cog-6-tooth",
        path: "inbox/settings",
        priority: 649,
        level: :admin,
        permission: module_key(),
        parent: :admin_inbox,
        visible: &PhoenixKitInbox.Mailboxes.can_manage_shared?/1,
        live_view: {PhoenixKitInbox.Web.SettingsLive, :index}
      }
    ]
  end

  @impl PhoenixKit.Module
  @doc """
  Entries of the avatar menu (core's `:user_menu` tab option), shown on every
  page to users who can use Inbox (`user_menu?/1`):

    * **Mail** — the inbox itself. An absolute path, which core leaves as it
      is, so the entry opens `/admin/inbox`; it has no `live_view`, so core
      generates no route for it.
    * **Mail settings** — the user's own settings (`Web.MySettingsLive`,
      `/dashboard/inbox-settings`, a route core generates): signatures,
      default Reply-To, personal senders. `personal: true` — it shows the
      viewer their own data — and still gated on `"inbox"`, so the sidebar
      does not offer it to users who cannot use Inbox.
  """
  def user_dashboard_tabs do
    [
      Tab.new!(
        id: :inbox_user_mail,
        label: "Mail",
        icon: "hero-envelope",
        path: "/admin/inbox",
        priority: 640,
        match: :prefix,
        group: :main,
        permission: module_key(),
        user_menu: &__MODULE__.user_menu?/1
      ),
      Tab.new!(
        id: :inbox_user_settings,
        label: "Mail settings",
        icon: "hero-cog-6-tooth",
        path: "inbox-settings",
        priority: 641,
        match: :prefix,
        group: :account,
        personal: true,
        permission: module_key(),
        live_view: {PhoenixKitInbox.Web.MySettingsLive, :index},
        user_menu: &__MODULE__.user_menu?/1
      )
    ]
  end

  @doc """
  Whether the avatar menu offers the Inbox entries to `scope`: the `"inbox"`
  permission, while the module is enabled.
  """
  @spec user_menu?(Scope.t() | nil) :: boolean()
  def user_menu?(scope), do: Scope.can?(scope, module_key())

  @impl PhoenixKit.Module
  @doc """
  Non-LiveView routes: the attachment download
  (`PhoenixKitInbox.Web.Routes`).
  """
  def route_module, do: PhoenixKitInbox.Web.Routes

  @impl PhoenixKit.Module
  @doc """
  Called by core before a user is deleted: archives their personal mailbox
  and hands each shared mailbox they own to its oldest active admin grantee
  (or archives it). The mail itself is kept by the foreign keys either way — see
  `PhoenixKitInbox.Mailboxes.handle_user_deletion/1`.
  """
  def before_user_delete(user_uuid), do: PhoenixKitInbox.Mailboxes.handle_user_deletion(user_uuid)

  @impl PhoenixKit.Module
  @doc "OTP apps whose templates Tailwind should scan for CSS classes."
  def css_sources, do: [:phoenix_kit_inbox]

  @impl PhoenixKit.Module
  @doc """
  Notification types this module contributes.

  One toggle: a user who mutes "Inbox" stops getting in-app notifications for
  new messages. The `actions` list must match the action strings
  `PhoenixKitInbox.Notify` emits.
  """
  def notification_types do
    [
      %{
        key: "inbox",
        label: "Inbox",
        description: "New messages in your mailboxes",
        actions: ["inbox.message_received"],
        default: true
      }
    ]
  end

  @impl PhoenixKit.Module
  @doc "Stats shown on the admin Modules page."
  def get_config do
    %{
      enabled: enabled?(),
      email_nudges: email_nudges_enabled?(),
      email_nudges_available: PhoenixKitInbox.Notify.email_nudges_available?()
    }
  rescue
    _ -> %{enabled: false}
  end

  # ===========================================================================
  # Settings
  # ===========================================================================

  @doc """
  Whether new-message email nudges are on.

  Off by default. The nudge only fires when it is on **and** the host also runs
  `phoenix_kit_emails` — see `PhoenixKitInbox.Notify`.
  """
  @spec email_nudges_enabled?() :: boolean()
  def email_nudges_enabled? do
    Settings.get_boolean_setting(@nudges_settings_key, false)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @doc "Turns the new-message email nudge on or off."
  @spec set_email_nudges(boolean()) :: term()
  def set_email_nudges(enabled) when is_boolean(enabled) do
    Settings.update_boolean_setting_with_module(@nudges_settings_key, enabled, module_key())
  end

  # ===========================================================================
  # Cross-module integration
  # ===========================================================================

  @doc """
  Resolves Inbox messages for `phoenix_kit_comments`' moderation admin, so a
  comment attached to a message links back to it.

  Registered by the host:

      config :phoenix_kit, :comment_resource_handlers, %{
        "inbox_message" => PhoenixKitInbox
      }
  """
  @spec resolve_comment_resources([binary()]) :: %{binary() => map()}
  def resolve_comment_resources(uuids) when is_list(uuids) do
    import Ecto.Query

    from(m in PhoenixKitInbox.Schemas.Message,
      where: m.uuid in ^uuids,
      select: {m.uuid, m.subject, m.sender_mailbox_uuid}
    )
    |> PhoenixKit.RepoHelper.repo().all()
    |> Map.new(fn {uuid, subject, mailbox_uuid} ->
      {uuid,
       %{
         title: subject || "(no subject)",
         path: PhoenixKitInbox.Paths.raw_message_path(mailbox_uuid, uuid)
       }}
    end)
  rescue
    _ -> %{}
  end

  def resolve_comment_resources(_), do: %{}
end
