defmodule PhoenixKitInbox.Web.Components.MailExplorer do
  @moduledoc """
  The mail of an object of the host, as a component a host page embeds: the
  conversations on the left (`MailTree`), the letter or conversation chosen
  on the right.

      <.live_component
        module={PhoenixKitInbox.Web.Components.MailExplorer}
        id="order-mail"
        scope={@scope}
        filter={[%{kind: "order", ref: @order.uuid}]}
        compose={&build_draft/1}
        can_link?={&can_link?/3}
      />

  What it shows is `PhoenixKitInbox.ObjectMail`: only the letters the viewer's
  own mailboxes (and the shared ones they hold a grant on) hold — never
  another person's personal mail, whatever the links say. Every action is
  checked again on the server with the viewer's `scope`; what the page offers
  only hides what would be refused.

  ## Attributes

    * `id`, `scope` (the viewer's `PhoenixKit.Users.Auth.Scope`), `filter`
      (the objects: `[%{kind: ..., ref: ...}]`) — required
    * `title` — the heading (default "Mail")
    * `folders` — the folder buttons to offer, of `:all`, `:inbox`, `:sent`
      (default all three)
    * `compose` — `nil` (default) or a function of one argument. With it the
      component offers "Compose" and "Reply"; on a click it calls
      `compose.(%{reply_to_message: message_uuid | nil})` and sends the
      result to the parent (below). The component never opens a form itself.
    * `can_link?` — `nil` (default) or `fn scope, kind, ref -> boolean end`,
      the host's say on linking and unlinking. Without it nothing can be
      linked or unlinked from here (`Links.link/5` refuses). Asked once per
      object each time the list is read, never while rendering; a callback
      that raises says no.
    * `link_to` — `nil` (default) or `%{kind: ..., ref: ...}`: the object a
      manual link goes to. Without it, the only object of `filter`; with
      several and no `link_to` the page offers no manual linking.
    * `link_label` — `nil` (default) or `fn %{kind: ..., ref: ...} ->
      String.t() | nil end`, how the host names an object ("Order #1042").
      Asked once per object each time the list is read; a callback that
      raises, or none, shows no name — the reference itself is never printed,
      only how the link came about (host, thread, subject, manual).

  ## Messages to the parent LiveView

    * `{:inbox_explorer, id, {:compose, draft}}`
    * `{:inbox_explorer, id, {:linked, message_uuid}}`
    * `{:inbox_explorer, id, {:unlinked, message_uuid}}`

  ## Live updates

  Call `attach/3` from the host's `mount/3` (again with the new filter when
  the page changes it; `detach/2` when it takes the explorer off) and the list
  follows new letters, delivery statuses and changes of access without a
  reload.
  """

  use PhoenixKitWeb, :live_component
  use Gettext, backend: PhoenixKitInbox.Gettext

  require Logger

  alias PhoenixKit.Utils.Format
  alias PhoenixKitInbox.Attachments
  alias PhoenixKitInbox.Body
  alias PhoenixKitInbox.Errors
  alias PhoenixKitInbox.External
  alias PhoenixKitInbox.Links
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.ObjectMail
  alias PhoenixKitInbox.Paths
  alias PhoenixKitInbox.Web.Components.MailExplorerHooks
  alias PhoenixKitInbox.Web.Components.MailTree

  @folders [:all, :inbox, :sent]
  @page 50

  # ── the component ───────────────────────────────────────────────────────────

  @doc """
  Keeps the explorers of a host page current: call it in the page's
  `mount/3` for each explorer, with the explorer's `id` and `filter`. See
  `PhoenixKitInbox.Web.Components.MailExplorerHooks` for what it subscribes
  to — and that the page then does not receive those events itself.
  """
  @spec attach(Phoenix.LiveView.Socket.t(), term(), [map()]) :: Phoenix.LiveView.Socket.t()
  defdelegate attach(socket, id, filter), to: MailExplorerHooks

  @doc """
  The reverse of `attach/3` for the explorer `id`, for a page that takes an
  explorer off. What only that explorer needed is let go; with the last one
  the page stops following mail altogether and handles those events itself
  again. Detaching an explorer that was not attached does nothing.
  """
  @spec detach(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  defdelegate detach(socket, id), to: MailExplorerHooks

  @impl true
  def update(%{refresh: true}, socket), do: {:ok, load(socket)}

  # A delivery status changed: matters only if that letter is on the page.
  def update(%{message_changed: uuid}, socket) do
    if find_entry(Map.get(socket.assigns, :threads, []), uuid),
      do: {:ok, load(socket)},
      else: {:ok, socket}
  end

  def update(assigns, socket) do
    assigns = assigns |> normalize_filter() |> normalize_link_to()

    stale? =
      not Map.has_key?(socket.assigns, :threads) or
        Enum.any?(~w(scope filter folders link_to)a, fn key ->
          Map.has_key?(assigns, key) and Map.get(socket.assigns, key) != assigns[key]
        end)

    socket =
      socket
      |> assign(assigns)
      |> assign_new(:title, fn -> gettext("Mail") end)
      |> assign_new(:folders, fn -> @folders end)
      |> assign_new(:compose, fn -> nil end)
      |> assign_new(:can_link?, fn -> nil end)
      |> assign_new(:link_label, fn -> nil end)
      |> assign_new(:link_to, fn -> nil end)
      |> assign_new(:folder, fn -> nil end)
      |> assign_new(:selected, fn -> nil end)
      |> assign_new(:picker, fn -> nil end)
      |> assign_new(:error, fn -> nil end)
      |> then(&assign(&1, :folder, offered_folder(&1.assigns.folder, &1.assigns.folders)))

    {:ok, if(stale?, do: load(socket), else: socket)}
  end

  # The objects, once each and in one order: another order of the same objects
  # is not a change of the filter.
  defp normalize_filter(%{filter: filter} = assigns),
    do: %{assigns | filter: ObjectMail.normalize_filter(filter)}

  defp normalize_filter(assigns), do: assigns

  defp normalize_link_to(%{link_to: link_to} = assigns),
    do: %{
      assigns
      | link_to: link_to |> List.wrap() |> ObjectMail.normalize_filter() |> List.first()
    }

  defp normalize_link_to(assigns), do: assigns

  defp offered_folder(folder, folders) do
    cond do
      folder in folders -> folder
      :all in folders -> :all
      true -> List.first(folders)
    end
  end

  # Reads the list again, with the viewer's access of this moment, and keeps
  # the selection if it still points at something on the page.
  defp load(socket) do
    %{scope: scope, filter: filter, folder: folder} = socket.assigns
    threads = ObjectMail.list_threads(scope, filter, folder: folder, limit: @page)

    socket
    |> assign(:threads, threads)
    |> assign(:selected, keep_or_first(socket.assigns[:selected], threads))
    |> assign(:picker, reload_picker(socket.assigns[:picker], scope))
    |> assign(:link_access, %{})
    |> assign(:link_labels, %{})
    |> assign_shown()
  end

  # What the reading pane needs, read when it changes and not on every render.
  defp assign_shown(socket) do
    socket |> assign_attachments() |> assign_objects()
  end

  # What the host says about each object the pane shows or may offer to link
  # (the link target and the links of the shown letters): asked once per object
  # per load, kept until the next load. A callback that fails says "no" /
  # "no label".
  defp assign_objects(socket) do
    objects = pane_objects(socket.assigns)

    socket
    |> assign(
      :link_access,
      ask_host(socket.assigns.link_access, objects, socket.assigns.can_link?, 3, fn fun,
                                                                                    {kind, ref} ->
        fun.(socket.assigns.scope, kind, ref) == true
      end)
    )
    |> assign(
      :link_labels,
      ask_host(socket.assigns.link_labels, objects, socket.assigns.link_label, 1, fn fun,
                                                                                     {kind, ref} ->
        host_label(fun.(%{kind: kind, ref: ref}))
      end)
    )
  end

  defp pane_objects(%{threads: threads, selected: selected} = assigns) do
    threads
    |> shown(selected)
    |> Enum.flat_map(fn entry -> Enum.map(entry.links, &{&1.kind, &1.ref}) end)
    |> Enum.concat(Enum.map(List.wrap(link_target(assigns)), &{&1.kind, &1.ref}))
    |> Enum.uniq()
  end

  defp ask_host(known, objects, fun, arity, ask) when is_function(fun, arity) do
    Enum.reduce(objects, known, &ask_once(&2, &1, fun, ask))
  end

  defp ask_host(known, _objects, _fun, _arity, _ask), do: known

  defp ask_once(known, {kind, _ref} = object, fun, ask) do
    Map.put_new_lazy(known, object, fn -> guarded(kind, fn -> ask.(fun, object) end) end)
  end

  defp host_label(label) when is_binary(label) and label != "", do: label
  defp host_label(_other), do: nil

  # A host callback that fails answers nothing (`nil`, which is "no" for a
  # yes/no question). Logged by the kind of object and of failure only: the
  # ref and the exception's message may carry what the host keeps private.
  defp guarded(kind, fun) do
    fun.()
  rescue
    exception -> failed(kind, exception.__struct__)
  catch
    thrown, _reason -> failed(kind, thrown)
  end

  defp failed(kind, failure) do
    Logger.warning(
      "[Inbox] MailExplorer: a host callback (can_link? or link_label) failed for a " <>
        "#{inspect(kind)} (#{inspect(failure)}), taken as no answer"
    )

    nil
  end

  # The files of the letters in the reading pane, as this viewer may see them
  # (the host's attachment policy, one batch): read when the pane changes,
  # not on every render.
  defp assign_attachments(
         %{assigns: %{scope: scope, threads: threads, selected: selected}} = socket
       ) do
    uuids = threads |> shown(selected) |> Enum.map(& &1.message.uuid)
    assign(socket, :attachments, Attachments.list_for_viewer_many(scope, uuids))
  end

  defp keep_or_first(selected, threads) do
    if selected && present?(threads, selected), do: selected, else: first(threads)
  end

  defp first([%{thread_uuid: uuid} | _]), do: {:thread, uuid}
  defp first([]), do: nil

  defp present?(threads, {:thread, uuid}), do: Enum.any?(threads, &(&1.thread_uuid == uuid))
  defp present?(threads, {:message, uuid}), do: find_entry(threads, uuid) != nil

  defp reload_picker(nil, _scope), do: nil
  defp reload_picker(_open, scope), do: ObjectMail.link_candidates(scope)

  # ── events ──────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("folder", %{"folder" => name}, socket) do
    case Enum.find(socket.assigns.folders, &(Atom.to_string(&1) == name)) do
      nil -> {:noreply, socket}
      folder -> {:noreply, socket |> assign(folder: folder, error: nil) |> load()}
    end
  end

  def handle_event("select", %{"kind" => kind, "uuid" => uuid}, socket) do
    selected =
      case kind do
        "thread" -> {:thread, uuid}
        "message" -> {:message, uuid}
        _ -> nil
      end

    if selected && present?(socket.assigns.threads, selected),
      do: {:noreply, socket |> assign(selected: selected, error: nil) |> assign_shown()},
      else: {:noreply, socket}
  end

  def handle_event("write", _params, socket), do: {:noreply, compose(socket, nil)}

  def handle_event("reply", %{"uuid" => uuid}, socket) do
    with true <- find_entry(socket.assigns.threads, uuid) != nil,
         {:ok, _read} <- Messages.fetch_for_scope(socket.assigns.scope, uuid) do
      {:noreply, compose(socket, uuid)}
    else
      false -> {:noreply, socket}
      {:error, reason} -> {:noreply, fail(socket, reason)}
    end
  end

  def handle_event("unlink", %{"link" => link_uuid}, socket) do
    case find_link(socket.assigns.threads, link_uuid) do
      nil ->
        {:noreply, socket}

      {entry, link} ->
        scope = socket.assigns.scope
        opts = link_opts(socket)

        case Links.unlink(scope, entry.message.uuid, link.kind, link.ref, opts) do
          :ok -> {:noreply, done(socket, {:unlinked, entry.message.uuid})}
          {:error, reason} -> {:noreply, fail(socket, reason)}
        end
    end
  end

  def handle_event("open_picker", _params, socket) do
    if linkable?(socket.assigns),
      do:
        {:noreply,
         assign(socket, picker: ObjectMail.link_candidates(socket.assigns.scope), error: nil)},
      else: {:noreply, socket}
  end

  def handle_event("close_picker", _params, socket), do: {:noreply, assign(socket, :picker, nil)}

  # Only a letter the picker showed, to the object the host named.
  def handle_event("link", %{"uuid" => uuid}, socket) do
    with %{kind: kind, ref: ref} <- link_target(socket.assigns),
         true <- picked?(socket.assigns.picker, uuid) do
      case Links.link(socket.assigns.scope, uuid, kind, ref, link_opts(socket)) do
        {:ok, _link} -> {:noreply, socket |> assign(:picker, nil) |> done({:linked, uuid})}
        {:error, reason} -> {:noreply, fail(socket, reason)}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp compose(socket, reply_to) do
    case socket.assigns.compose do
      compose when is_function(compose, 1) ->
        notify(socket, {:compose, compose.(%{reply_to_message: reply_to})})

      _ ->
        socket
    end
  end

  defp done(socket, message) do
    socket |> assign(:error, nil) |> notify(message) |> load()
  end

  defp notify(socket, message) do
    send(self(), {:inbox_explorer, socket.assigns.id, message})
    socket
  end

  defp fail(socket, reason), do: assign(socket, :error, Errors.message(reason))

  # `Links` asks the host; without a host's say there is none.
  defp link_opts(%{assigns: %{can_link?: fun}}) when is_function(fun, 3), do: [can_link?: fun]
  defp link_opts(_socket), do: []

  # Where a manual link goes: the object the host named, else the only
  # object of the filter. With several and no say, nowhere.
  defp link_target(%{link_to: %{kind: _, ref: _} = object}), do: object
  defp link_target(%{filter: [object]}), do: object
  defp link_target(_assigns), do: nil

  # The picker is offered when the host lets this viewer link to the target
  # (as asked once in load/1).
  defp linkable?(%{link_access: access} = assigns) do
    case link_target(assigns) do
      %{kind: kind, ref: ref} -> Map.get(access, {kind, ref}, false) == true
      nil -> false
    end
  end

  defp picked?(picker, uuid) when is_list(picker),
    do: Enum.any?(picker, &(&1.message.uuid == uuid))

  defp picked?(_picker, _uuid), do: false

  defp find_entry(threads, message_uuid) do
    Enum.find_value(threads, fn thread ->
      Enum.find(thread.messages, &(&1.message.uuid == message_uuid))
    end)
  end

  defp find_link(threads, link_uuid) do
    threads
    |> Enum.flat_map(& &1.messages)
    |> Enum.find_value(fn entry ->
      case Enum.find(entry.links, &(&1.uuid == link_uuid)) do
        nil -> nil
        link -> {entry, link}
      end
    end)
  end

  defp shown(_threads, nil), do: []

  defp shown(threads, {:thread, uuid}) do
    case Enum.find(threads, &(&1.thread_uuid == uuid)) do
      nil -> []
      thread -> thread.messages
    end
  end

  defp shown(threads, {:message, uuid}) do
    case find_entry(threads, uuid) do
      nil -> []
      entry -> [entry]
    end
  end

  # ── rendering ───────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:letters, shown(assigns.threads, assigns.selected))
      |> assign(:can_pick?, linkable?(assigns))
      |> assign(:now, DateTime.utc_now())

    ~H"""
    <div id={"mail-explorer-#{@id}"} class="flex flex-col gap-3">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <h3 class="text-base font-semibold">{@title}</h3>
        <div class="flex flex-wrap items-center gap-2">
          <div
            :if={length(@folders) > 1}
            class="join"
            role="group"
            aria-label={gettext("Folder")}
          >
            <button
              :for={folder <- @folders}
              type="button"
              class={["btn btn-sm join-item", @folder == folder && "btn-active"]}
              aria-pressed={to_string(@folder == folder)}
              phx-click="folder"
              phx-value-folder={folder}
              phx-target={@myself}
            >
              {folder_label(folder)}
            </button>
          </div>
          <button
            :if={@can_pick?}
            type="button"
            class="btn btn-sm btn-outline"
            phx-click="open_picker"
            phx-target={@myself}
          >
            <.icon name="hero-link" class="w-4 h-4" />
            {gettext("Link a letter")}
          </button>
        </div>
      </div>

      <div :if={@error} role="alert" class="alert alert-error alert-soft py-2 text-sm">
        <.icon name="hero-exclamation-circle" class="w-5 h-5" />
        <span>{@error}</span>
      </div>

      <.picker :if={@picker} id={@id} letters={@picker} target={@myself} />

      <div class="grid gap-4 md:grid-cols-[minmax(16rem,22rem)_1fr]">
        <div id={"mail-list-#{@id}"}>
          <MailTree.tree :if={@threads != []} id={@id} threads={@threads} selected={@selected} target={@myself} />
          <p :if={@threads == []} class="text-sm text-base-content/60">
            {gettext("No letters yet.")}
          </p>
        </div>

        <div id={"mail-detail-#{@id}"} class="flex flex-col gap-3">
          <p :if={@letters == []} class="text-sm text-base-content/60">
            {gettext("Select a conversation to read it.")}
          </p>
          <.letter
            :for={entry <- @letters}
            id={@id}
            entry={entry}
            attachments={Map.get(@attachments, entry.message.uuid, [])}
            link_access={@link_access}
            link_labels={@link_labels}
            reply?={is_function(@compose, 1)}
            target={@myself}
            now={@now}
          />
        </div>
      </div>

      <div class="flex flex-wrap items-center justify-between gap-2">
        <span class="text-xs text-base-content/60">
          {gettext("Other people's personal mail is not shown here.")}
        </span>
        <button
          :if={is_function(@compose, 1)}
          type="button"
          class="btn btn-sm btn-primary"
          phx-click="write"
          phx-target={@myself}
        >
          <.icon name="hero-pencil-square" class="w-4 h-4" />
          {gettext("Compose")}
        </button>
      </div>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:letters, :list, required: true)
  attr(:target, :any, required: true)

  defp picker(assigns) do
    ~H"""
    <div id={"mail-picker-#{@id}"} class="card border border-base-300 bg-base-100">
      <div class="card-body gap-2 p-4">
        <div class="flex items-center justify-between gap-2">
          <h4 class="font-medium">{gettext("Pick a letter to link")}</h4>
          <button
            type="button"
            class="btn btn-ghost btn-xs"
            title={gettext("Close")}
            phx-click="close_picker"
            phx-target={@target}
          >
            <.icon name="hero-x-mark" class="w-4 h-4" />
          </button>
        </div>
        <p :if={@letters == []} class="text-sm text-base-content/60">
          {gettext("No letters without a link.")}
        </p>
        <button
          :for={entry <- @letters}
          type="button"
          class="flex flex-col gap-0.5 rounded-lg border border-base-300 px-3 py-2 text-left text-sm hover:bg-base-200"
          phx-click="link"
          phx-value-uuid={entry.message.uuid}
          phx-target={@target}
        >
          <span class="font-medium">{entry.message.subject || gettext("(no subject)")}</span>
          <span class="text-xs opacity-70">{MailTree.people(entry.message)}</span>
        </button>
      </div>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:entry, :map, required: true)
  attr(:attachments, :list, default: [])
  attr(:link_access, :map, default: %{})
  attr(:link_labels, :map, default: %{})
  attr(:reply?, :boolean, required: true)
  attr(:target, :any, required: true)
  attr(:now, :any, required: true)

  defp letter(assigns) do
    message = assigns.entry.message
    assigns = assign(assigns, message: message, html: Body.html(message))

    ~H"""
    <article
      id={"mail-letter-#{@id}-#{@message.uuid}"}
      class="card border border-base-300 bg-base-100"
    >
      <div class="card-body gap-3 p-4">
        <div class="flex items-start justify-between gap-2">
          <h4 class="font-medium">{@message.subject || gettext("(no subject)")}</h4>
          <span class="shrink-0 text-xs opacity-60">{full_time(@message.sent_at)}</span>
        </div>

        <div class="flex flex-wrap items-center gap-1 text-xs">
          <span class={[
            "badge badge-sm",
            if(@entry.direction == :sent, do: "badge-neutral badge-outline", else: "badge-info badge-outline")
          ]}>
            {MailTree.direction_label(@entry.direction)}
          </span>
          <span class="font-medium">{MailTree.sender_name(@message.metadata["sender"])}</span>
          <span
            :for={recipient <- @message.metadata["recipients"] || []}
            class="badge badge-ghost badge-sm gap-1"
          >
            <span class="uppercase opacity-60">{recipient["role"]}</span>
            {recipient["name"] || recipient["handle"]}
          </span>
        </div>

        <div :if={@entry.external != []} class="flex flex-wrap items-center gap-1 text-xs">
          <span
            :for={row <- @entry.external}
            id={"mail-external-#{@id}-#{row.uuid}"}
            class={["badge badge-sm gap-1", external_class(@entry.direction, row, @now)]}
            title={@entry.direction == :sent && row.error}
          >
            <span class="uppercase opacity-60">{row.role}</span>
            {row.name || row.address}
            <span :if={@entry.direction == :sent} class="opacity-70">
              · {external_label(External.display_status(row, @now))}
            </span>
          </span>
        </div>

        <div :if={@entry.links != []} class="flex flex-wrap items-center gap-1 text-xs">
          <span :for={link <- @entry.links} class="badge badge-ghost badge-sm gap-1">
            <.icon name="hero-link" class="w-3 h-3" />
            {Map.get(@link_labels, {link.kind, link.ref})}
            <span class="opacity-60">{MailTree.source_label(link.source)}</span>
            <button
              :if={Map.get(@link_access, {link.kind, link.ref}, false)}
              type="button"
              class="btn btn-ghost btn-xs btn-circle h-4 min-h-0 w-4"
              title={gettext("Unlink")}
              aria-label={gettext("Unlink")}
              phx-click="unlink"
              phx-value-link={link.uuid}
              phx-target={@target}
            >
              <.icon name="hero-x-mark" class="w-3 h-3" />
            </button>
          </span>
        </div>

        <div class="divider my-0"></div>

        <div :if={@html} class="prose prose-sm max-w-none">{@html}</div>
        <div :if={!@html} class="prose max-w-none whitespace-pre-wrap text-sm">
          {@message.body || ""}
        </div>

        <%!-- Plain links: each is a download from the module's controller, which
              checks the reader again. A file the host's policy withholds shows
              no name or size. --%>
        <div :if={@attachments != []} class="flex flex-wrap gap-2">
          <%= for {status, attachment} <- @attachments do %>
            <a
              :if={status == :ok}
              id={"mail-attachment-#{@id}-#{attachment.uuid}"}
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
              id={"mail-attachment-#{@id}-#{attachment.uuid}"}
              class="btn btn-sm btn-disabled gap-2 normal-case"
            >
              <.icon name="hero-no-symbol" class="w-4 h-4 shrink-0" />
              {gettext("Attachment not available")}
            </span>
          <% end %>
        </div>

        <div :if={@reply?} class="card-actions justify-end">
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="reply"
            phx-value-uuid={@message.uuid}
            phx-target={@target}
          >
            <.icon name="hero-arrow-uturn-left" class="w-4 h-4" />
            {gettext("Reply")}
          </button>
        </div>
      </div>
    </article>
    """
  end

  defp folder_label(:all), do: gettext("All")
  defp folder_label(:inbox), do: gettext("Inbox")
  defp folder_label(:sent), do: pgettext("mail explorer folder", "Sent")

  # The delivery state is for the sender; a reader sees only who it went to.
  defp external_class(:sent, row, now) do
    case External.display_status(row, now) do
      :sent -> "badge-success badge-outline"
      :failed -> "badge-error badge-outline"
      :pending -> "badge-warning badge-outline"
      :unknown -> "badge-ghost"
    end
  end

  defp external_class(_direction, _row, _now), do: "badge-ghost"

  defp external_label(:sent), do: gettext("sent")
  defp external_label(:failed), do: gettext("not delivered")
  defp external_label(:pending), do: gettext("sending…")
  defp external_label(:unknown), do: gettext("unknown — check the email log")

  defp full_time(nil), do: ""
  defp full_time(at), do: Calendar.strftime(at, "%d.%m.%Y %H:%M")
end
