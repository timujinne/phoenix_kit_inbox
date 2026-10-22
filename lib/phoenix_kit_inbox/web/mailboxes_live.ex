defmodule PhoenixKitInbox.Web.MailboxesLive do
  @moduledoc """
  Shared mailbox management — create shared mailboxes and decide who can read,
  write, or administer each one.

  Personal mailboxes are deliberately absent from this page. They're created
  automatically, there's exactly one per user, and nobody else is ever granted
  access to one — there is nothing here to manage.

  ## Who can see this page

  The page itself needs the `"inbox"` module permission. Individual mailboxes
  are then filtered to those the viewer holds `"admin"` on (which their own
  created mailboxes always are), so a `"write"` grantee on `support@` can send
  as it but can't hand access to someone else.

  Creating a shared mailbox needs `inbox.manage_shared`. Without it the form
  is not rendered — and `Mailboxes.create_shared_mailbox/2` refuses a forged
  submit anyway, since the check lives there.

  The "Access" panel lists who holds a grant by name and offers colleagues
  to pick from (`Mailboxes.search_users/3`: members only, not the viewer),
  narrowed as the viewer types. `Mailboxes.grant_access/4` checks the grant.

  The "Signatures" panel (`Web.SignatureEditor`) writes a mailbox's
  signatures; it is offered on an active mailbox the viewer administers
  when they hold `inbox.manage_shared` too — what `PhoenixKitInbox.Signatures`
  checks on every write.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitInbox.Gettext

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitInbox.Errors
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Paths
  alias PhoenixKitInbox.Schemas.Mailbox
  alias PhoenixKitInbox.Web.SignatureEditor

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    user = socket.assigns[:phoenix_kit_current_user]

    socket =
      socket
      |> assign(:page_title, gettext("Mailboxes"))
      |> assign(:page_subtitle, gettext("Shared mailboxes and who can use them"))
      |> assign(:module_access, scope && Scope.has_module_access?(scope, "inbox"))
      |> assign(:scope, scope)
      |> assign(:can_manage_shared, Mailboxes.can_manage_shared?(scope))
      |> assign(:current_user, user)
      |> assign(:form, to_form(Mailboxes.change_mailbox(%Mailbox{})))
      |> assign(:expanded, nil)
      |> assign(:grants, [])
      |> assign(:candidates, [])
      |> assign(:grant_form, grant_form(""))
      |> SignatureEditor.assign_editor(nil)
      |> load_mailboxes()

    {:ok, socket}
  end

  defp load_mailboxes(socket) do
    user_uuid = user_uuid(socket)

    mailboxes =
      Mailboxes.list_shared_mailboxes()
      |> Enum.map(&%{mailbox: &1, access: Mailboxes.access_level(&1, user_uuid)})
      |> Enum.filter(&(&1.access != nil))

    assign(socket, :mailboxes, mailboxes)
  end

  # ── Events ──────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("validate", %{"mailbox" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(Mailboxes.change_mailbox(%Mailbox{}, params)))}
  end

  def handle_event("create", %{"mailbox" => params}, socket) do
    case Mailboxes.create_shared_mailbox(socket.assigns.scope, params) do
      {:ok, mailbox} ->
        {:noreply,
         socket
         |> assign(:form, to_form(Mailboxes.change_mailbox(%Mailbox{})))
         |> load_mailboxes()
         |> put_flash(:info, gettext("Mailbox “%{name}” created.", name: mailbox.name))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Errors.message(reason))}
    end
  end

  # Who holds access is for the mailbox's admins: the button is only drawn for
  # them, so an event for any other mailbox (a read grantee's own row, a
  # forged uuid) shows nothing.
  def handle_event("toggle_grants", %{"uuid" => uuid}, socket) do
    cond do
      socket.assigns.expanded == uuid ->
        {:noreply, assign(socket, expanded: nil, grants: [], candidates: [])}

      admin_of?(socket, uuid) ->
        {:noreply,
         socket
         |> assign(expanded: uuid, grants: Mailboxes.list_grant_holders(uuid))
         |> search_candidates("")}

      true ->
        {:noreply, socket}
    end
  end

  # Fires for the colleague and access selects too; only a new term searches.
  def handle_event("grant_search", params, socket) do
    term = Map.get(params, "q", "")

    if term == socket.assigns.grant_form.params["q"],
      do: {:noreply, socket},
      else: {:noreply, search_candidates(socket, term)}
  end

  def handle_event("grant", %{"user_uuid" => target, "access" => access}, socket) do
    with {:ok, mailbox} <- expanded_mailbox(socket),
         {:ok, _grant} <-
           Mailboxes.grant_access(socket.assigns.scope, mailbox, String.trim(target), access) do
      {:noreply,
       socket
       |> assign(:grants, Mailboxes.list_grant_holders(mailbox.uuid))
       |> search_candidates("")
       |> put_flash(:info, gettext("Access granted."))}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, Errors.message(reason))}
    end
  end

  def handle_event("revoke", %{"user_uuid" => target}, socket) do
    with {:ok, mailbox} <- expanded_mailbox(socket),
         :ok <- Mailboxes.revoke_access(socket.assigns.scope, mailbox, target) do
      {:noreply,
       socket
       |> assign(:grants, Mailboxes.list_grant_holders(mailbox.uuid))
       |> put_flash(:info, gettext("Access revoked."))}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, Errors.message(reason))}
    end
  end

  def handle_event("toggle_signatures", %{"uuid" => uuid}, socket) do
    case socket.assigns.sig_mailbox do
      %{uuid: ^uuid} -> {:noreply, SignatureEditor.assign_editor(socket, nil)}
      _ -> {:noreply, SignatureEditor.assign_editor(socket, signing_mailbox(socket, uuid))}
    end
  end

  def handle_event("sig_" <> _ = event, params, socket),
    do: SignatureEditor.handle_event(event, params, socket)

  def handle_event("archive", %{"uuid" => uuid}, socket) do
    with {:ok, mailbox} <- Mailboxes.fetch_mailbox(uuid),
         {:ok, _} <- Mailboxes.archive_mailbox(socket.assigns.scope, mailbox) do
      {:noreply,
       socket
       |> close_signatures(uuid)
       |> load_mailboxes()
       |> put_flash(:info, gettext("Mailbox archived."))}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, Errors.message(reason))}
    end
  end

  defp admin_of?(socket, uuid),
    do: Enum.any?(socket.assigns.mailboxes, &(&1.mailbox.uuid == uuid and &1.access == "admin"))

  defp search_candidates(socket, term) do
    candidates =
      case user_uuid(socket) do
        nil -> []
        uuid -> Mailboxes.search_users(uuid, term)
      end

    socket
    |> assign(:candidates, candidates)
    |> assign(:grant_form, grant_form(term))
  end

  # A listed active mailbox whose signatures the viewer may write, or nil.
  defp signing_mailbox(%{assigns: %{can_manage_shared: true, mailboxes: mailboxes}}, uuid) do
    Enum.find_value(mailboxes, fn
      %{mailbox: %{uuid: ^uuid, status: "active"} = mailbox, access: "admin"} -> mailbox
      _ -> nil
    end)
  end

  defp signing_mailbox(_socket, _uuid), do: nil

  defp close_signatures(%{assigns: %{sig_mailbox: %{uuid: uuid}}} = socket, uuid),
    do: SignatureEditor.assign_editor(socket, nil)

  defp close_signatures(socket, _uuid), do: socket

  defp grant_form(term), do: to_form(%{"q" => term, "user_uuid" => "", "access" => "read"})

  defp expanded_mailbox(%{assigns: %{expanded: nil}}), do: {:error, :mailbox_not_found}
  defp expanded_mailbox(%{assigns: %{expanded: uuid}}), do: Mailboxes.fetch_mailbox(uuid)

  defp user_uuid(socket) do
    case socket.assigns[:current_user] do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  end

  # ── Render ──────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col px-4 py-6 gap-6">
      <div :if={not @module_access} class="alert alert-warning">
        <.icon name="hero-lock-closed" class="w-5 h-5" />
        <span>{gettext("You don't have permission to use Inbox.")}</span>
      </div>

      <div :if={@module_access} class="flex flex-col gap-6">
        <.link navigate={Paths.inbox()} class="btn btn-ghost btn-sm self-start">
          <.icon name="hero-arrow-left" class="w-4 h-4" />
          {gettext("Back to mailbox")}
        </.link>

        <.create_form :if={@can_manage_shared} form={@form} />
        <.mailbox_table
          can_create={@can_manage_shared}
          mailboxes={@mailboxes}
          expanded={@expanded}
          grants={@grants}
          candidates={@candidates}
          grant_form={@grant_form}
          sig_mailbox={@sig_mailbox}
          signatures={@signatures}
          sig_editing={@sig_editing}
          sig_form={@sig_form}
        />
      </div>
    </div>
    """
  end

  attr(:form, :any, required: true)

  defp create_form(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow max-w-2xl">
      <div class="card-body gap-3">
        <h2 class="card-title text-base">{gettext("New shared mailbox")}</h2>

        <.form
          for={@form}
          id="new-shared-mailbox-form"
          phx-change="validate"
          phx-submit="create"
          class="flex flex-col gap-3"
        >
          <.input
            field={@form[:name]}
            type="text"
            label={gettext("Name")}
            placeholder={gettext("Support")}
          />
          <.input
            field={@form[:slug]}
            type="text"
            label={gettext("Slug")}
            placeholder={gettext("Derived from the name when left blank")}
          />
          <.input
            field={@form[:address]}
            type="text"
            label={gettext("Address")}
            placeholder="support@example.com"
          />

          <div class="card-actions justify-end">
            <button type="submit" class="btn btn-primary btn-sm">
              <.icon name="hero-plus" class="w-4 h-4" />
              {gettext("Create mailbox")}
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  attr(:can_create, :boolean, required: true)
  attr(:mailboxes, :list, required: true)
  attr(:expanded, :any, required: true)
  attr(:grants, :list, required: true)
  attr(:candidates, :list, required: true)
  attr(:grant_form, :any, required: true)
  attr(:sig_mailbox, :any, required: true)
  attr(:signatures, :list, required: true)
  attr(:sig_editing, :any, required: true)
  attr(:sig_form, :any, required: true)

  defp mailbox_table(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body gap-3">
        <h2 class="card-title text-base">{gettext("Shared mailboxes")}</h2>

        <div :if={@mailboxes == []}>
          <.empty_state
            icon="hero-user-group"
            title={gettext("No shared mailboxes yet.")}
            description={
              if(@can_create,
                do: gettext("Create one above to let a team share an address."),
                else: gettext("Shared mailboxes you are given access to appear here.")
              )
            }
          />
        </div>

        <div :if={@mailboxes != []} class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>{gettext("Name")}</th>
                <th>{gettext("Address")}</th>
                <th>{gettext("Your access")}</th>
                <th class="text-right">{gettext("Actions")}</th>
              </tr>
            </thead>
            <tbody>
              <%= for %{mailbox: mailbox, access: access} <- @mailboxes do %>
                <tr>
                  <td class="font-medium">{mailbox.name}</td>
                  <td class="text-sm text-base-content/70">{mailbox.address || mailbox.slug}</td>
                  <td><span class="badge badge-ghost badge-sm">{access}</span></td>
                  <td class="text-right whitespace-nowrap">
                    <.link
                      navigate={Paths.inbox(mailbox: mailbox.uuid)}
                      class="btn btn-ghost btn-xs"
                    >
                      {gettext("Open")}
                    </.link>
                    <button
                      :if={access == "admin"}
                      class="btn btn-ghost btn-xs"
                      phx-click="toggle_grants"
                      phx-value-uuid={mailbox.uuid}
                    >
                      {gettext("Access")}
                    </button>
                    <button
                      :if={access == "admin" and @can_create and mailbox.status == "active"}
                      class="btn btn-ghost btn-xs"
                      phx-click="toggle_signatures"
                      phx-value-uuid={mailbox.uuid}
                    >
                      {gettext("Signatures")}
                    </button>
                    <button
                      :if={access == "admin"}
                      class="btn btn-ghost btn-xs text-error"
                      phx-click="archive"
                      phx-value-uuid={mailbox.uuid}
                      data-confirm={gettext("Archive this mailbox?")}
                    >
                      {gettext("Archive")}
                    </button>
                  </td>
                </tr>
                <tr :if={@expanded == mailbox.uuid}>
                  <td colspan="4" class="bg-base-200">
                    <.grant_panel grants={@grants} candidates={@candidates} grant_form={@grant_form} />
                  </td>
                </tr>
                <tr :if={@sig_mailbox && @sig_mailbox.uuid == mailbox.uuid}>
                  <td colspan="4" class="bg-base-200">
                    <SignatureEditor.editor
                      id="mailbox-signatures"
                      signatures={@signatures}
                      editing={@sig_editing}
                      form={@sig_form}
                    />
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  attr(:grants, :list, required: true)
  attr(:candidates, :list, required: true)
  attr(:grant_form, :any, required: true)

  defp grant_panel(assigns) do
    ~H"""
    <div class="flex flex-col gap-3 py-2">
      <ul :if={@grants != []} class="flex flex-col gap-1">
        <li
          :for={grant <- @grants}
          id={"grant-#{grant.user_uuid}"}
          class="flex items-center gap-2 text-sm"
        >
          <span class="font-medium">{grant.name}</span>
          <span :if={grant.username} class="text-base-content/60">@{grant.username}</span>
          <span class="badge badge-ghost badge-sm">{grant.access}</span>
          <button
            class="btn btn-ghost btn-xs text-error"
            phx-click="revoke"
            phx-value-user_uuid={grant.user_uuid}
          >
            {gettext("Revoke")}
          </button>
        </li>
      </ul>

      <p :if={@grants == []} class="text-sm text-base-content/60">
        {gettext("Only you can use this mailbox so far.")}
      </p>

      <.form
        for={@grant_form}
        id="grant-form"
        phx-change="grant_search"
        phx-submit="grant"
        class="flex flex-wrap items-end gap-2"
      >
        <.input
          field={@grant_form[:q]}
          type="search"
          label={gettext("Find a colleague")}
          placeholder={gettext("Name, @username or email")}
          phx-debounce="300"
          class="input input-sm"
        />
        <.select
          id="grant-user"
          name="user_uuid"
          value=""
          label={gettext("Colleague")}
          prompt={if(@candidates == [], do: gettext("Nobody found"), else: nil)}
          options={Enum.map(@candidates, &{candidate_label(&1), &1.uuid})}
          class="select-sm"
        />
        <.select
          name="access"
          value="read"
          options={[
            {gettext("Read"), "read"},
            {gettext("Write"), "write"},
            {gettext("Admin"), "admin"}
          ]}
          class="select-sm"
        />
        <button type="submit" class="btn btn-primary btn-sm" disabled={@candidates == []}>
          {gettext("Grant access")}
        </button>
      </.form>
    </div>
    """
  end

  defp candidate_label(%{name: name, username: username}) when username not in [nil, ""],
    do: "#{name} (@#{username})"

  defp candidate_label(%{name: name}), do: name
end
