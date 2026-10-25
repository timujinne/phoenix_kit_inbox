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

  Both are also re-checked when they change under an open page: on core's
  scope refresh (`phoenix_kit_scope_changed/1`) and on Inbox's own access
  events (`PhoenixKitInbox.AccessEvents`) — the mailbox list is reloaded, and
  a mailbox no longer readable is left for the personal one
  (`PhoenixKitInbox.Web.ScopeRefresh`).

  ## External recipients

  The reading pane lists a message's external recipients with their status
  (`PhoenixKitInbox.External`) — Bcc ones to the sending mailbox only — and
  follows a send still under way: the LiveView subscribes to the external
  updates of the user's mailboxes and of the one open. "Retry" is shown to
  the sending mailbox's writers when `Messages.retry_available?/1` says so;
  `Messages.retry_external/3` checks again.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitInbox.Gettext

  require Logger

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Format
  alias PhoenixKitInbox.Attachments
  alias PhoenixKitInbox.Body
  alias PhoenixKitInbox.Errors
  alias PhoenixKitInbox.External
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Paths
  alias PhoenixKitInbox.Schemas.Delivery
  alias PhoenixKitInbox.Web.ScopeRefresh

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
    socket =
      socket
      |> assign(:page_title, gettext("Inbox"))
      |> assign(:page_subtitle, gettext("Messages between users of this application"))
      |> ScopeRefresh.assign_scope()
      |> assign_module_access()
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
      |> assign(:attachments, [])
      |> assign(:externals, [])
      |> assign(:externals_sender, false)
      |> assign(:retry_available, false)
      |> assign(:followed, MapSet.new())
      |> load_mailboxes()
      |> ScopeRefresh.subscribe([:user])

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign_module_access(socket)

    socket =
      if socket.assigns.module_access,
        do: apply_params(socket, params),
        else: clear_mailbox(socket)

    {:noreply, follow_externals(socket)}
  end

  @doc false
  # Core's scope refresh: the scope changed under the page.
  def phoenix_kit_scope_changed(socket) do
    socket
    |> ScopeRefresh.assign_scope()
    |> refresh_access()
  end

  defp assign_module_access(socket),
    do: assign(socket, :module_access, Scope.can?(socket.assigns.scope, "inbox"))

  # Everything derived from the scope and the grants, again: the gate, the
  # mailbox list with the external updates followed for it, the open
  # mailbox. A mailbox no longer readable is left for the personal one; a
  # page that just gained Inbox opens it. Losing Inbox only clears the page —
  # core moves the visitor off an admin page that lost its permission.
  defp refresh_access(socket) do
    had_access? = socket.assigns.module_access

    socket =
      socket
      |> assign_module_access()
      |> load_mailboxes()

    socket =
      cond do
        not socket.assigns.module_access -> clear_mailbox(socket)
        socket.assigns.mailbox -> recheck_mailbox(socket, socket.assigns.mailbox)
        not had_access? -> push_patch(socket, to: Paths.inbox())
        true -> socket
      end

    follow_externals(socket)
  end

  defp recheck_mailbox(socket, mailbox) do
    case Mailboxes.authorize_scope(socket.assigns.scope, mailbox, "read") do
      {:ok, fresh} ->
        socket
        |> assign(:mailbox, fresh)
        |> assign(:access, Mailboxes.access_level(fresh, current_user_uuid(socket)))
        |> load_messages()
        |> reselect()

      {:error, _reason} ->
        socket
        |> clear_mailbox()
        |> put_flash(
          :error,
          gettext("You no longer have access to “%{name}”.", name: mailbox.name)
        )
        |> push_patch(to: Paths.inbox())
    end
  end

  # The open message read again — not reopened, which would mark it seen —
  # with what its sender may do on it (Retry needs write).
  defp reselect(%{assigns: %{selected: %{message: message}}} = socket) do
    socket = refresh_selected(socket)
    if socket.assigns.selected, do: assign_externals(socket, message), else: socket
  end

  defp reselect(socket), do: socket

  # The external updates followed (`:followed`): those of the listed
  # mailboxes and of the open one — an archived mailbox left open, or opened
  # by its URL, is not listed. Each topic is subscribed to once; one neither
  # listed nor open any more is dropped. Run after mount's params and on
  # every param or access change.
  defp follow_externals(socket) do
    if connected?(socket) do
      open = if mailbox = socket.assigns.mailbox, do: [mailbox.uuid], else: []
      wanted = MapSet.new(open ++ Enum.map(socket.assigns.mailboxes, & &1.uuid))
      followed = socket.assigns.followed

      wanted |> MapSet.difference(followed) |> Enum.each(&External.subscribe/1)
      followed |> MapSet.difference(wanted) |> Enum.each(&External.unsubscribe/1)
      assign(socket, :followed, wanted)
    else
      socket
    end
  end

  # The mailbox list is read at mount and on an access change
  # (`refresh_access/1`), not per patch — that would be a query per folder
  # click.
  #
  # Without Inbox access nothing is loaded: the personal mailbox is created
  # lazily here, and a user who can't use Inbox must not get one by visiting.
  defp load_mailboxes(%{assigns: %{module_access: access}} = socket) when access != true,
    do: assign(socket, mailboxes: [], personal_mailbox: nil)

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
         {:ok, mailbox} <- Mailboxes.authorize_scope(socket.assigns.scope, mailbox, "read") do
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
        |> clear_mailbox()
        |> put_flash(:error, Errors.message(reason))
    end
  end

  defp clear_mailbox(socket) do
    socket
    |> close_selected()
    |> assign(mailbox: nil, access: nil, entries: [], total: 0, unseen_counts: %{})
  end

  defp resolve_mailbox(socket, nil) do
    case socket.assigns[:personal_mailbox] do
      nil -> {:error, :mailbox_not_found}
      mailbox -> {:ok, mailbox}
    end
  end

  defp resolve_mailbox(_socket, uuid), do: Mailboxes.fetch_mailbox(uuid)

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

  defp select_message(socket, nil), do: close_selected(socket)

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
        |> assign(
          :attachments,
          Attachments.list_for_viewer(socket.assigns.scope, entry.message.uuid)
        )
        |> assign_externals(entry.message)
        |> assign(:unseen_counts, Mailboxes.unseen_counts(socket.assigns.mailbox.uuid))

      {:error, reason} ->
        socket
        |> close_selected()
        |> put_flash(:error, Errors.message(reason))
    end
  end

  # How the external part went is the sender's business: the sending mailbox
  # sees each status (and error), its writers get Retry; a recipient sees
  # only the To and Cc addresses.
  defp assign_externals(socket, message) do
    mailbox = socket.assigns.mailbox
    externals = Messages.list_external_recipients(message.uuid, mailbox.uuid)
    sender? = message.sender_mailbox_uuid == mailbox.uuid

    retry? =
      sender? and socket.assigns.access in ~w(write admin) and
        Enum.any?(externals, &(&1.status == "failed")) and Messages.retry_available?(message)

    socket
    |> assign(:externals, externals)
    |> assign(:externals_sender, sender?)
    |> assign(:retry_available, retry?)
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

  def handle_event(
        "retry_external",
        %{"uuid" => uuid},
        %{assigns: %{mailbox: %{} = mailbox}} = socket
      ) do
    case Messages.retry_external(socket.assigns.scope, mailbox, uuid) do
      {:ok, :pending} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Sending again."))
         |> refresh_externals()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Errors.message(reason))}
    end
  end

  def handle_event("retry_external", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:inbox_external_updated, message_uuid}, socket) do
    case socket.assigns.selected do
      %{message: %{uuid: ^message_uuid}} -> {:noreply, refresh_externals(socket)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:inbox_access_changed, _what}, socket),
    do: {:noreply, refresh_access(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp refresh_externals(%{assigns: %{selected: %{message: message}, mailbox: mailbox}} = socket)
       when is_map(mailbox) do
    case Mailboxes.authorize_scope(socket.assigns.scope, mailbox, "read") do
      {:ok, _} -> assign_externals(socket, message)
      {:error, _} -> clear_mailbox(socket)
    end
  end

  defp refresh_externals(socket), do: socket

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
      {:error, _} -> close_selected(socket)
    end
  end

  defp close_selected(socket) do
    assign(socket,
      selected: nil,
      recipients: [],
      attachments: [],
      externals: [],
      externals_sender: false,
      retry_available: false
    )
  end

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
              attachments={@attachments}
              externals={@externals}
              externals_sender={@externals_sender}
              retry_available={@retry_available}
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
      <span>{gettext("You don't have permission to use Inbox.")}</span>
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
        {gettext("New message")}
      </.link>

      <button class="btn btn-ghost btn-sm" phx-click="refresh" title={gettext("Refresh")}>
        <.icon name="hero-arrow-path" class="w-4 h-4" />
      </button>

      <div class="flex-1"></div>

      <.link navigate={Paths.mailboxes()} class="btn btn-ghost btn-sm">
        <.icon name="hero-user-group" class="w-4 h-4" />
        {gettext("Mailboxes")}
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
        <%!-- In a form: LiveView sends a change only from an input inside one --%>
        <form
          :if={length(@mailboxes) > 1}
          id="mailbox-switch-form"
          phx-change="select_mailbox"
        >
          <.select
            name="mailbox"
            value={@mailbox && @mailbox.uuid}
            options={Enum.map(@mailboxes, &{&1.name, &1.uuid})}
            class="select-sm"
          />
        </form>

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

        <label class="flex cursor-pointer items-start gap-1.5">
          <input
            type="checkbox"
            class="checkbox checkbox-xs checkbox-primary shrink-0 mt-px"
            checked={@unseen_only}
            phx-click="toggle_unseen_only"
          />
          <span class="min-w-0 break-words text-xs">{gettext("Unseen only")}</span>
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
            placeholder={gettext("Search")}
            class="input input-sm w-full"
            phx-debounce="300"
          />
        </form>

        <div :if={@entries == []} class="py-10">
          <.empty_state
            icon="hero-inbox"
            title={gettext("Empty list.")}
            description={gettext("Nothing in this folder yet.")}
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
              title={gettext("Star")}
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
                {entry.message.subject || gettext("(no subject)")}
              </div>
              <div class="truncate text-xs text-base-content/60">
                {Body.preview(entry.message)}
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
  attr(:attachments, :list, default: [])
  attr(:externals, :list, default: [])
  attr(:externals_sender, :boolean, default: false)
  attr(:retry_available, :boolean, default: false)
  attr(:mailbox, :any, required: true)
  attr(:access, :any, required: true)
  attr(:folder, :string, required: true)

  defp reading_pane(%{selected: nil} = assigns) do
    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body items-center justify-center min-h-64">
        <p class="text-base-content/50">
          {gettext("Select any message in the list to view it here.")}
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
            {@selected.message.subject || gettext("(no subject)")}
          </h2>
          <button class="btn btn-ghost btn-xs" phx-click="close_message" title={gettext("Close")}>
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

        <.external_recipients
          :if={@externals != []}
          externals={@externals}
          sender={@externals_sender}
          message={@selected.message}
          retry_available={@retry_available}
        />

        <div class="divider my-0"></div>

        <.message_body message={@selected.message} />

        <%!-- Plain links, not LiveView navigation: each is a download from
              the module's controller, which checks the reader again. One the
              host's policy withholds from this reader shows no name or size. --%>
        <div :if={@attachments != []} id="message-attachments" class="flex flex-wrap gap-2">
          <%= for {status, attachment} <- @attachments do %>
            <a
              :if={status == :ok}
              id={"message-attachment-#{attachment.uuid}"}
              href={Paths.attachment(attachment.uuid)}
              class="btn btn-sm btn-outline gap-2 max-w-full normal-case"
              title={gettext("Download")}
              download
            >
              <.icon name="hero-paper-clip" class="w-4 h-4 shrink-0" />
              <span class="truncate">{attachment.filename}</span>
              <span class="text-xs opacity-60 shrink-0">{Format.bytes(attachment.size_bytes)}</span>
            </a>
            <span
              :if={status == :withheld}
              id={"message-attachment-#{attachment.uuid}"}
              class="btn btn-sm btn-disabled gap-2 normal-case"
            >
              <.icon name="hero-no-symbol" class="w-4 h-4 shrink-0" />
              {gettext("Attachment not available")}
            </span>
          <% end %>
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

  attr(:externals, :list, required: true)
  attr(:sender, :boolean, required: true)
  attr(:message, :any, required: true)
  attr(:retry_available, :boolean, required: true)

  defp external_recipients(assigns) do
    assigns = assign(assigns, :now, DateTime.utc_now())

    ~H"""
    <div id="external-recipients" class="flex flex-wrap items-center gap-2 text-xs">
      <span
        :for={row <- @externals}
        id={"external-#{row.uuid}"}
        class={[
          "badge badge-sm gap-1",
          if(@sender, do: external_badge(External.display_status(row, @now)), else: "badge-ghost")
        ]}
        title={@sender && row.error}
      >
        <span class="uppercase opacity-60">{row.role}</span>
        {row.name || row.address}
        <span :if={@sender} class="opacity-70">
          · {external_label(External.display_status(row, @now))}
        </span>
      </span>
      <button
        :if={@retry_available}
        id="retry-external"
        class="btn btn-ghost btn-xs"
        phx-click="retry_external"
        phx-value-uuid={@message.uuid}
      >
        <.icon name="hero-arrow-path" class="w-3 h-3" />
        {gettext("Retry")}
      </button>
    </div>
    """
  end

  defp external_badge(:sent), do: "badge-success badge-outline"
  defp external_badge(:failed), do: "badge-error badge-outline"
  defp external_badge(:pending), do: "badge-warning badge-outline"
  defp external_badge(:unknown), do: "badge-ghost"

  defp external_label(:sent), do: gettext("sent")
  defp external_label(:failed), do: gettext("not delivered")
  defp external_label(:pending), do: gettext("sending…")
  defp external_label(:unknown), do: gettext("unknown — check the email log")

  attr(:message, :any, required: true)

  # A Markdown body is sanitized HTML (`PhoenixKitInbox.Body`); any other is
  # shown as typed, escaped.
  defp message_body(assigns) do
    assigns = assign(assigns, :html, Body.html(assigns.message))

    ~H"""
    <div :if={@html} id="message-body" class="prose prose-sm max-w-none">{@html}</div>
    <div :if={!@html} id="message-body" class="prose max-w-none whitespace-pre-wrap text-sm">
      {@message.body || ""}
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
      <%!-- A draft is opened to be written on: it is nobody's to reply to or
            forward until it is sent. --%>
      <.link
        :if={@message.status == "draft" and @access in ~w(write admin)}
        id="edit-draft"
        navigate={Paths.compose(mailbox: @mailbox.uuid, draft: @message.uuid)}
        class="btn btn-primary btn-sm"
      >
        <.icon name="hero-pencil-square" class="w-4 h-4" />
        {gettext("Edit draft")}
      </.link>

      <.link
        :if={@message.status != "draft" and @access in ~w(write admin)}
        navigate={Paths.compose(mailbox: @mailbox.uuid, reply_to: @message.uuid)}
        class="btn btn-primary btn-sm"
      >
        <.icon name="hero-arrow-uturn-left" class="w-4 h-4" />
        {gettext("Reply")}
      </.link>

      <.link
        :if={@message.status != "draft" and @access in ~w(write admin)}
        navigate={Paths.compose(mailbox: @mailbox.uuid, forward: @message.uuid)}
        class="btn btn-ghost btn-sm"
      >
        <.icon name="hero-arrow-uturn-right" class="w-4 h-4" />
        {gettext("Forward")}
      </.link>

      <button class="btn btn-ghost btn-sm" phx-click="toggle_seen" phx-value-uuid={@message.uuid}>
        <.icon
          name={if @delivery.seen_at, do: "hero-envelope", else: "hero-envelope-open"}
          class="w-4 h-4"
        />
        {if @delivery.seen_at, do: gettext("Mark unread"), else: gettext("Mark read")}
      </button>

      <button
        :if={@folder != "archive" and @access in ~w(write admin)}
        class="btn btn-ghost btn-sm"
        phx-click="move"
        phx-value-uuid={@message.uuid}
        phx-value-folder="archive"
      >
        <.icon name="hero-archive-box" class="w-4 h-4" />
        {gettext("Archive")}
      </button>

      <button
        :if={@folder != "spam" and @access in ~w(write admin)}
        class="btn btn-ghost btn-sm"
        phx-click="move"
        phx-value-uuid={@message.uuid}
        phx-value-folder="spam"
      >
        <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
        {gettext("Spam")}
      </button>

      <button
        :if={@folder != "trash" and @access in ~w(write admin)}
        class="btn btn-ghost btn-sm text-error"
        phx-click="move"
        phx-value-uuid={@message.uuid}
        phx-value-folder="trash"
      >
        <.icon name="hero-trash" class="w-4 h-4" />
        {gettext("Trash")}
      </button>

      <button
        :if={@folder == "trash" and @access in ~w(write admin)}
        class="btn btn-error btn-sm"
        phx-click="delete_forever"
        phx-value-uuid={@message.uuid}
        data-confirm={gettext("Delete this message from your mailbox permanently?")}
      >
        <.icon name="hero-trash" class="w-4 h-4" />
        {gettext("Delete forever")}
      </button>
    </div>
    """
  end

  # ── View helpers ────────────────────────────────────────────────────────────

  defp selected?(nil, _entry), do: false
  defp selected?(%{message: %{uuid: uuid}}, %{message: %{uuid: uuid}}), do: true
  defp selected?(_, _), do: false

  defp folder_icon(folder), do: Map.get(@folder_icons, folder, "hero-folder")

  defp folder_label("inbox"), do: gettext("Inbox")
  defp folder_label("sent"), do: gettext("Sent")
  defp folder_label("drafts"), do: gettext("Drafts")
  defp folder_label("spam"), do: gettext("Spam")
  defp folder_label("trash"), do: gettext("Trash")
  defp folder_label("archive"), do: gettext("Archive")
  defp folder_label(other), do: other

  defp unseen_count(counts, folder), do: Map.get(counts, folder, 0)

  defp short_time(nil), do: ""

  defp short_time(datetime) do
    Calendar.strftime(datetime, "%d %b", month_names())
  end

  defp full_time(nil), do: ""

  defp full_time(datetime) do
    Calendar.strftime(datetime, "%d %b %Y, %H:%M", month_names())
  end

  # Calendar.strftime/3 takes the month names as a function of the month.
  defp month_names do
    [abbreviated_month_names: &abbreviated_month/1]
  end

  defp abbreviated_month(1), do: pgettext("month, abbreviated", "Jan")
  defp abbreviated_month(2), do: pgettext("month, abbreviated", "Feb")
  defp abbreviated_month(3), do: pgettext("month, abbreviated", "Mar")
  defp abbreviated_month(4), do: pgettext("month, abbreviated", "Apr")
  defp abbreviated_month(5), do: pgettext("month, abbreviated", "May")
  defp abbreviated_month(6), do: pgettext("month, abbreviated", "Jun")
  defp abbreviated_month(7), do: pgettext("month, abbreviated", "Jul")
  defp abbreviated_month(8), do: pgettext("month, abbreviated", "Aug")
  defp abbreviated_month(9), do: pgettext("month, abbreviated", "Sep")
  defp abbreviated_month(10), do: pgettext("month, abbreviated", "Oct")
  defp abbreviated_month(11), do: pgettext("month, abbreviated", "Nov")
  defp abbreviated_month(12), do: pgettext("month, abbreviated", "Dec")
end
