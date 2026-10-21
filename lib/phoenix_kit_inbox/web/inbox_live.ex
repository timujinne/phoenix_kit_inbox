defmodule PhoenixKitInbox.Web.InboxLive do
  @moduledoc """
  The mailbox — folder sidebar, message list, reading pane.

  ## One LiveView, patched navigation

  Everything except composing happens here. Which mailbox, which folder, and
  which message is open are **query params**, read in `handle_params/3`;
  clicking a folder or a message is a `push_patch`, not a `navigate`. That
  keeps the socket (and the mailbox list, and the scroll position) alive across
  every interaction the way a real webmail client does, and it makes every
  view of the mailbox a shareable URL.

  The render function follows the section-decomposition pattern from
  `phoenix_kit_hello_world`'s `ComponentsLive`: `render/1` is a flat dispatch
  over three panes, each a private function component declaring the assigns it
  reads.

  ## Access

  Two gates, checked on every param change rather than only at mount — a user
  can hand-edit `?mailbox=` in the URL:

    1. `Scope.has_module_access?(scope, "inbox")` — can they use Inbox at all
    2. `Mailboxes.authorize/3` — can they open *this* mailbox
  """

  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitInbox.Errors
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Paths
  alias PhoenixKitInbox.Schemas.Delivery

  @folder_icons %{
    "inbox" => "hero-inbox-arrow-down",
    "sent" => "hero-paper-airplane",
    "drafts" => "hero-document",
    "spam" => "hero-exclamation-triangle",
    "trash" => "hero-trash",
    "archive" => "hero-archive-box"
  }

  @per_page 50

  # ── Mount / params ──────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    user = socket.assigns[:phoenix_kit_current_user]

    socket =
      socket
      |> assign(:page_title, gettext_str("Inbox"))
      |> assign(:page_subtitle, gettext_str("Messages between users of this application"))
      |> assign(:module_access, scope && Scope.has_module_access?(scope, "inbox"))
      |> assign(:scope, scope)
      |> assign(:current_user, user)
      |> assign(:mailboxes, [])
      |> assign(:mailbox, nil)
      |> assign(:access, nil)
      |> assign(:folder, "inbox")
      |> assign(:search, "")
      |> assign(:unseen_only, false)
      |> assign(:entries, [])
      |> assign(:total, 0)
      |> assign(:page, 1)
      |> assign(:unseen_counts, %{})
      |> assign(:selected, nil)
      |> assign(:recipients, [])

    {:ok, load_mailboxes(socket)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if socket.assigns.module_access do
      {:noreply, apply_params(socket, params)}
    else
      {:noreply, socket}
    end
  end

  # Mailbox list is stable for the life of the socket — grants change rarely
  # and a re-read on every patch would be a query per folder click.
  #
  # Without Inbox access nothing is loaded: the personal mailbox is created
  # lazily here, and a user who can't use Inbox must not get one by visiting.
  defp load_mailboxes(%{assigns: %{module_access: access}} = socket) when access != true,
    do: assign(socket, :personal_mailbox, nil)

  defp load_mailboxes(%{assigns: %{current_user: user}} = socket) when is_map(user) do
    case Mailboxes.ensure_user_mailbox(user) do
      {:ok, personal} ->
        socket
        |> assign(:mailboxes, Mailboxes.list_accessible_mailboxes(user.uuid))
        |> assign(:personal_mailbox, personal)

      {:error, reason} ->
        Logger.warning("[Inbox] could not resolve personal mailbox: #{inspect(reason)}")

        socket
        |> assign(:mailboxes, [])
        |> assign(:personal_mailbox, nil)
        |> put_flash(:error, Errors.message(reason))
    end
  end

  defp load_mailboxes(socket), do: assign(socket, :personal_mailbox, nil)

  defp apply_params(socket, params) do
    with {:ok, mailbox} <- resolve_mailbox(socket, params["mailbox"]),
         :ok <- authorize(socket, mailbox, "read") do
      socket
      |> assign(:mailbox, mailbox)
      |> assign(:access, Mailboxes.access_level(mailbox, current_user_uuid(socket)))
      |> assign(:folder, normalize_folder(params["folder"]))
      |> assign(:search, params["search"] || "")
      |> assign(:unseen_only, params["unseen"] == "1")
      |> assign(:page, parse_page(params["page"]))
      |> load_messages()
      |> select_message(params["message"])
    else
      {:error, reason} ->
        socket
        |> assign(:mailbox, nil)
        |> assign(:entries, [])
        |> put_flash(:error, Errors.message(reason))
    end
  end

  defp resolve_mailbox(socket, nil) do
    case socket.assigns[:personal_mailbox] do
      nil -> {:error, :mailbox_not_found}
      mailbox -> {:ok, mailbox}
    end
  end

  defp resolve_mailbox(_socket, uuid), do: Mailboxes.fetch_mailbox(uuid)

  defp authorize(socket, mailbox, level) do
    Mailboxes.authorize(mailbox, current_user_uuid(socket), level)
  end

  defp normalize_folder(folder) when folder in ~w(inbox sent drafts spam trash archive),
    do: folder

  defp normalize_folder(_), do: "inbox"

  defp parse_page(nil), do: 1

  defp parse_page(value) do
    case Integer.parse(to_string(value)) do
      {page, _} when page > 0 -> page
      _ -> 1
    end
  end

  defp current_user_uuid(socket) do
    case socket.assigns[:current_user] do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  end

  # ── Data loading ────────────────────────────────────────────────────────────

  defp load_messages(%{assigns: %{mailbox: nil}} = socket), do: socket

  defp load_messages(%{assigns: assigns} = socket) do
    opts = [
      limit: @per_page,
      offset: (assigns.page - 1) * @per_page,
      unseen_only: assigns.unseen_only,
      search: assigns.search
    ]

    socket
    |> assign(:entries, Messages.list_folder(assigns.mailbox.uuid, assigns.folder, opts))
    |> assign(:total, Messages.count_folder(assigns.mailbox.uuid, assigns.folder, opts))
    |> assign(:unseen_counts, Mailboxes.unseen_counts(assigns.mailbox.uuid))
  end

  defp select_message(socket, nil), do: assign(socket, selected: nil, recipients: [])

  defp select_message(%{assigns: %{mailbox: nil}} = socket, _), do: socket

  defp select_message(socket, message_uuid) do
    case Messages.fetch_for_mailbox(socket.assigns.mailbox.uuid, message_uuid) do
      {:ok, entry} ->
        # Opening a message marks it seen — but only in a folder where that
        # means something. Re-opening your own draft shouldn't touch counts.
        entry = maybe_mark_seen(socket, entry)

        socket
        |> assign(:selected, entry)
        |> assign(
          :recipients,
          Messages.list_recipients(message_uuid, socket.assigns.mailbox.uuid)
        )
        |> assign(:unseen_counts, Mailboxes.unseen_counts(socket.assigns.mailbox.uuid))

      {:error, reason} ->
        socket
        |> assign(selected: nil, recipients: [])
        |> put_flash(:error, Errors.message(reason))
    end
  end

  defp maybe_mark_seen(socket, %{delivery: %Delivery{seen_at: nil}} = entry) do
    case Messages.mark_seen(socket.assigns.scope, socket.assigns.mailbox, entry.message.uuid) do
      {:ok, delivery} -> %{entry | delivery: delivery}
      _ -> entry
    end
  end

  defp maybe_mark_seen(_socket, entry), do: entry

  # ── Events ──────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("select_folder", %{"folder" => folder}, socket) do
    {:noreply, patch_to(socket, folder: folder, message: nil, page: 1)}
  end

  def handle_event("select_mailbox", %{"mailbox" => uuid}, socket) do
    {:noreply, patch_to(socket, mailbox: uuid, folder: "inbox", message: nil, page: 1)}
  end

  def handle_event("open_message", %{"uuid" => uuid}, socket) do
    {:noreply, patch_to(socket, message: uuid)}
  end

  def handle_event("close_message", _params, socket) do
    {:noreply, patch_to(socket, message: nil)}
  end

  def handle_event("search", %{"search" => term}, socket) do
    {:noreply, patch_to(socket, search: term, message: nil, page: 1)}
  end

  def handle_event("toggle_unseen_only", _params, socket) do
    unseen = if socket.assigns.unseen_only, do: nil, else: "1"
    {:noreply, patch_to(socket, unseen: unseen, message: nil, page: 1)}
  end

  def handle_event("paginate", %{"page" => page}, socket) do
    {:noreply, patch_to(socket, page: page, message: nil)}
  end

  def handle_event("toggle_star", %{"uuid" => uuid}, socket) do
    {:noreply, mutate(socket, &Messages.toggle_star(&1, &2, uuid))}
  end

  def handle_event("toggle_seen", %{"uuid" => uuid}, socket) do
    entry = Enum.find(socket.assigns.entries, &(&1.message.uuid == uuid))
    seen? = entry && entry.delivery.seen_at

    {:noreply,
     mutate(socket, fn scope, mailbox ->
       if seen?,
         do: Messages.mark_unseen(scope, mailbox, uuid),
         else: Messages.mark_seen(scope, mailbox, uuid)
     end)}
  end

  def handle_event("move", %{"uuid" => uuid, "folder" => folder}, socket) do
    socket =
      mutate(socket, &Messages.move_to_folder(&1, &2, uuid, folder))

    # The message just left the folder we're looking at, so close the pane.
    {:noreply, if(socket.assigns.folder == folder, do: socket, else: close_selected(socket))}
  end

  def handle_event("delete_forever", %{"uuid" => uuid}, socket) do
    socket = mutate(socket, &Messages.purge(&1, &2, uuid))
    {:noreply, close_selected(socket)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, load_messages(socket)}
  end

  # Runs a mutation against the current mailbox with the session scope, then
  # reloads the list. The context function checks the scope's grant level
  # itself (read for seen/star, write for move/purge); this only renders the
  # outcome.
  defp mutate(%{assigns: %{mailbox: nil}} = socket, _fun), do: socket

  defp mutate(socket, fun) do
    case fun.(socket.assigns.scope, socket.assigns.mailbox) do
      {:error, reason} ->
        put_flash(socket, :error, Errors.message(reason))

      _ok ->
        socket
        |> load_messages()
        |> refresh_selected()
    end
  end

  defp refresh_selected(%{assigns: %{selected: nil}} = socket), do: socket

  defp refresh_selected(%{assigns: %{selected: %{message: message}}} = socket) do
    case Messages.fetch_for_mailbox(socket.assigns.mailbox.uuid, message.uuid) do
      {:ok, entry} -> assign(socket, :selected, entry)
      {:error, _} -> assign(socket, selected: nil, recipients: [])
    end
  end

  defp close_selected(socket), do: assign(socket, selected: nil, recipients: [])

  # Every navigation in this LiveView is "the current view, with these bits
  # changed" — so the caller passes only what differs and the rest is read off
  # the socket. Keeps each handle_event a one-liner and makes it impossible to
  # accidentally drop the active folder while opening a message.
  defp patch_to(socket, overrides) do
    assigns = socket.assigns
    overrides = Map.new(overrides)

    opts = [
      mailbox: Map.get(overrides, :mailbox, assigns.mailbox && assigns.mailbox.uuid),
      folder: Map.get(overrides, :folder, assigns.folder),
      message: Map.get(overrides, :message, assigns.selected && assigns.selected.message.uuid),
      search: Map.get(overrides, :search, assigns.search),
      unseen: Map.get(overrides, :unseen, if(assigns.unseen_only, do: "1")),
      page: Map.get(overrides, :page, assigns.page)
    ]

    push_patch(socket, to: Paths.inbox(opts))
  end

  # ── Render ──────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col px-4 py-6 gap-4">
      <.no_access_notice :if={not @module_access} />

      <div :if={@module_access} class="flex flex-col gap-4">
        <.toolbar mailbox={@mailbox} access={@access} folder={@folder} />

        <div class="grid grid-cols-1 lg:grid-cols-12 gap-4 items-start">
          <div class="lg:col-span-3 xl:col-span-2">
            <.folder_sidebar
              mailboxes={@mailboxes}
              mailbox={@mailbox}
              folder={@folder}
              unseen_only={@unseen_only}
              unseen_counts={@unseen_counts}
            />
          </div>

          <div class="lg:col-span-4 xl:col-span-4">
            <.message_list
              entries={@entries}
              selected={@selected}
              search={@search}
              folder={@folder}
              total={@total}
              page={@page}
            />
          </div>

          <div class="lg:col-span-5 xl:col-span-6">
            <.reading_pane
              selected={@selected}
              recipients={@recipients}
              mailbox={@mailbox}
              access={@access}
              folder={@folder}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp no_access_notice(assigns) do
    ~H"""
    <div class="alert alert-warning">
      <.icon name="hero-lock-closed" class="w-5 h-5" />
      <span>{gettext_str("You don't have permission to use Inbox.")}</span>
    </div>
    """
  end

  # ── Toolbar ─────────────────────────────────────────────────────────────────

  attr(:mailbox, :any, required: true)
  attr(:access, :any, required: true)
  attr(:folder, :string, required: true)

  defp toolbar(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <.link
        :if={@mailbox && @access in ~w(write admin)}
        navigate={Paths.compose(mailbox: @mailbox.uuid)}
        class="btn btn-primary btn-sm"
      >
        <.icon name="hero-pencil-square" class="w-4 h-4" />
        {gettext_str("New message")}
      </.link>

      <button class="btn btn-ghost btn-sm" phx-click="refresh" title={gettext_str("Refresh")}>
        <.icon name="hero-arrow-path" class="w-4 h-4" />
      </button>

      <div class="flex-1"></div>

      <.link navigate={Paths.mailboxes()} class="btn btn-ghost btn-sm">
        <.icon name="hero-user-group" class="w-4 h-4" />
        {gettext_str("Mailboxes")}
      </.link>

      <div :if={@mailbox} class="badge badge-outline gap-2 py-3">
        <.icon name="hero-at-symbol" class="w-3.5 h-3.5" />
        {@mailbox.address || @mailbox.slug}
      </div>
    </div>
    """
  end

  # ── Folder sidebar ──────────────────────────────────────────────────────────

  attr(:mailboxes, :list, required: true)
  attr(:mailbox, :any, required: true)
  attr(:folder, :string, required: true)
  attr(:unseen_only, :boolean, required: true)
  attr(:unseen_counts, :map, required: true)

  defp folder_sidebar(assigns) do
    assigns = assign(assigns, :folders, Delivery.folders())

    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body p-3 gap-3">
        <.select
          :if={length(@mailboxes) > 1}
          name="mailbox"
          value={@mailbox && @mailbox.uuid}
          options={Enum.map(@mailboxes, &{&1.name, &1.uuid})}
          class="select-sm"
          phx-change="select_mailbox"
        />

        <ul class="menu menu-sm w-full p-0">
          <li :for={folder <- @folders}>
            <button
              type="button"
              phx-click="select_folder"
              phx-value-folder={folder}
              class={["flex items-center gap-2", folder == @folder && "active font-semibold"]}
            >
              <.icon name={folder_icon(folder)} class="w-4 h-4 shrink-0" />
              <span class="flex-1 text-left">{folder_label(folder)}</span>
              <span :if={unseen_count(@unseen_counts, folder) > 0} class="badge badge-primary badge-sm">
                {unseen_count(@unseen_counts, folder)}
              </span>
            </button>
          </li>
        </ul>

        <div class="divider my-0"></div>

        <label class="label cursor-pointer justify-start gap-2 px-2">
          <input
            type="checkbox"
            class="checkbox checkbox-sm checkbox-primary"
            checked={@unseen_only}
            phx-click="toggle_unseen_only"
          />
          <span class="text-sm">{gettext_str("Unseen only")}</span>
        </label>
      </div>
    </div>
    """
  end

  # ── Message list ────────────────────────────────────────────────────────────

  attr(:entries, :list, required: true)
  attr(:selected, :any, required: true)
  attr(:search, :string, required: true)
  attr(:folder, :string, required: true)
  attr(:total, :integer, required: true)
  attr(:page, :integer, required: true)

  defp message_list(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body p-3 gap-3">
        <form phx-change="search" phx-submit="search" class="flex items-center gap-2">
          <.icon name="hero-magnifying-glass" class="w-4 h-4 opacity-60 shrink-0" />
          <input
            type="search"
            name="search"
            value={@search}
            placeholder={gettext_str("Search")}
            class="input input-sm w-full"
            phx-debounce="300"
          />
        </form>

        <div :if={@entries == []} class="py-10">
          <.empty_state
            icon="hero-inbox"
            title={gettext_str("Empty list.")}
            description={gettext_str("Nothing in this folder yet.")}
          />
        </div>

        <ul :if={@entries != []} class="flex flex-col divide-y divide-base-300">
          <li
            :for={entry <- @entries}
            class={[
              "flex items-start gap-2 py-2 px-1 cursor-pointer hover:bg-base-200 rounded",
              selected?(@selected, entry) && "bg-base-200"
            ]}
            phx-click="open_message"
            phx-value-uuid={entry.message.uuid}
          >
            <button
              type="button"
              class="btn btn-ghost btn-xs px-1"
              phx-click="toggle_star"
              phx-value-uuid={entry.message.uuid}
              title={gettext_str("Star")}
            >
              <.icon
                name={if entry.delivery.starred, do: "hero-star-solid", else: "hero-star"}
                class={if entry.delivery.starred, do: "w-4 h-4 text-warning", else: "w-4 h-4"}
              />
            </button>

            <div class="min-w-0 flex-1">
              <div class={[
                "truncate text-sm",
                is_nil(entry.delivery.seen_at) && "font-bold"
              ]}>
                {entry.message.subject || gettext_str("(no subject)")}
              </div>
              <div class="truncate text-xs text-base-content/60">
                {preview(entry.message.body)}
              </div>
            </div>

            <div class="text-xs text-base-content/50 shrink-0 whitespace-nowrap">
              {short_time(entry.message.sent_at || entry.message.inserted_at)}
            </div>
          </li>
        </ul>

        <.list_pagination :if={@total > 50} total={@total} page={@page} />
      </div>
    </div>
    """
  end

  attr(:total, :integer, required: true)
  attr(:page, :integer, required: true)

  defp list_pagination(assigns) do
    assigns = assign(assigns, :pages, ceil(assigns.total / @per_page))

    ~H"""
    <div class="join self-center">
      <button
        class="join-item btn btn-sm"
        disabled={@page <= 1}
        phx-click="paginate"
        phx-value-page={@page - 1}
      >
        «
      </button>
      <button class="join-item btn btn-sm btn-disabled">{@page} / {@pages}</button>
      <button
        class="join-item btn btn-sm"
        disabled={@page >= @pages}
        phx-click="paginate"
        phx-value-page={@page + 1}
      >
        »
      </button>
    </div>
    """
  end

  # ── Reading pane ────────────────────────────────────────────────────────────

  attr(:selected, :any, required: true)
  attr(:recipients, :list, required: true)
  attr(:mailbox, :any, required: true)
  attr(:access, :any, required: true)
  attr(:folder, :string, required: true)

  defp reading_pane(%{selected: nil} = assigns) do
    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body items-center justify-center min-h-64">
        <p class="text-base-content/50">
          {gettext_str("Select any message in the list to view it here.")}
        </p>
      </div>
    </div>
    """
  end

  defp reading_pane(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body gap-4">
        <div class="flex items-start justify-between gap-2">
          <h2 class="card-title text-lg">
            {@selected.message.subject || gettext_str("(no subject)")}
          </h2>
          <button class="btn btn-ghost btn-xs" phx-click="close_message" title={gettext_str("Close")}>
            <.icon name="hero-x-mark" class="w-4 h-4" />
          </button>
        </div>

        <div class="flex flex-wrap items-center gap-2 text-xs">
          <span
            :for={recipient <- @recipients}
            id={"recipient-#{recipient.mailbox.uuid}"}
            class="badge badge-ghost badge-sm gap-1"
            title={recipient.role}
          >
            <span class="uppercase opacity-60">{recipient.role}</span>
            {recipient.mailbox.name}
          </span>
          <span class="text-base-content/50">
            {full_time(@selected.message.sent_at || @selected.message.inserted_at)}
          </span>
        </div>

        <div class="divider my-0"></div>

        <div class="prose max-w-none whitespace-pre-wrap text-sm">
          {@selected.message.body || ""}
        </div>

        <.message_actions
          :if={@mailbox}
          message={@selected.message}
          delivery={@selected.delivery}
          mailbox={@mailbox}
          access={@access}
          folder={@folder}
        />
      </div>
    </div>
    """
  end

  attr(:message, :any, required: true)
  attr(:delivery, :any, required: true)
  attr(:mailbox, :any, required: true)
  attr(:access, :any, required: true)
  attr(:folder, :string, required: true)

  defp message_actions(assigns) do
    ~H"""
    <div class="card-actions justify-end flex-wrap gap-2">
      <.link
        :if={@access in ~w(write admin)}
        navigate={Paths.compose(mailbox: @mailbox.uuid, reply_to: @message.uuid)}
        class="btn btn-primary btn-sm"
      >
        <.icon name="hero-arrow-uturn-left" class="w-4 h-4" />
        {gettext_str("Reply")}
      </.link>

      <.link
        :if={@access in ~w(write admin)}
        navigate={Paths.compose(mailbox: @mailbox.uuid, forward: @message.uuid)}
        class="btn btn-ghost btn-sm"
      >
        <.icon name="hero-arrow-uturn-right" class="w-4 h-4" />
        {gettext_str("Forward")}
      </.link>

      <button class="btn btn-ghost btn-sm" phx-click="toggle_seen" phx-value-uuid={@message.uuid}>
        <.icon
          name={if @delivery.seen_at, do: "hero-envelope", else: "hero-envelope-open"}
          class="w-4 h-4"
        />
        {if @delivery.seen_at, do: gettext_str("Mark unread"), else: gettext_str("Mark read")}
      </button>

      <button
        :if={@folder != "archive" and @access in ~w(write admin)}
        class="btn btn-ghost btn-sm"
        phx-click="move"
        phx-value-uuid={@message.uuid}
        phx-value-folder="archive"
      >
        <.icon name="hero-archive-box" class="w-4 h-4" />
        {gettext_str("Archive")}
      </button>

      <button
        :if={@folder != "spam" and @access in ~w(write admin)}
        class="btn btn-ghost btn-sm"
        phx-click="move"
        phx-value-uuid={@message.uuid}
        phx-value-folder="spam"
      >
        <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
        {gettext_str("Spam")}
      </button>

      <button
        :if={@folder != "trash" and @access in ~w(write admin)}
        class="btn btn-ghost btn-sm text-error"
        phx-click="move"
        phx-value-uuid={@message.uuid}
        phx-value-folder="trash"
      >
        <.icon name="hero-trash" class="w-4 h-4" />
        {gettext_str("Trash")}
      </button>

      <button
        :if={@folder == "trash" and @access in ~w(write admin)}
        class="btn btn-error btn-sm"
        phx-click="delete_forever"
        phx-value-uuid={@message.uuid}
        data-confirm={gettext_str("Delete this message from your mailbox permanently?")}
      >
        <.icon name="hero-trash" class="w-4 h-4" />
        {gettext_str("Delete forever")}
      </button>
    </div>
    """
  end

  # ── View helpers ────────────────────────────────────────────────────────────

  defp selected?(nil, _entry), do: false
  defp selected?(%{message: %{uuid: uuid}}, %{message: %{uuid: uuid}}), do: true
  defp selected?(_, _), do: false

  defp folder_icon(folder), do: Map.get(@folder_icons, folder, "hero-folder")

  defp folder_label("inbox"), do: gettext_str("Inbox")
  defp folder_label("sent"), do: gettext_str("Sent")
  defp folder_label("drafts"), do: gettext_str("Drafts")
  defp folder_label("spam"), do: gettext_str("Spam")
  defp folder_label("trash"), do: gettext_str("Trash")
  defp folder_label("archive"), do: gettext_str("Archive")
  defp folder_label(other), do: other

  defp unseen_count(counts, folder), do: Map.get(counts, folder, 0)

  defp preview(nil), do: ""

  defp preview(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 120)
  end

  defp short_time(nil), do: ""

  defp short_time(datetime) do
    Calendar.strftime(datetime, "%d %b")
  end

  defp full_time(nil), do: ""

  defp full_time(datetime) do
    Calendar.strftime(datetime, "%d %b %Y, %H:%M")
  end

  # All user-facing copy goes through core's gettext backend — see the
  # "Wrap user-facing strings in gettext" convention.
  defp gettext_str(msgid), do: Gettext.gettext(PhoenixKitWeb.Gettext, msgid)
end
