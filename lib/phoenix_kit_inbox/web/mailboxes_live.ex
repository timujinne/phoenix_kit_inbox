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
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitInbox.Gettext

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitInbox.Errors
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Paths
  alias PhoenixKitInbox.Schemas.Mailbox

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
      |> assign(:grant_form, to_form(%{"user_uuid" => "", "access" => "read"}))
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

  def handle_event("toggle_grants", %{"uuid" => uuid}, socket) do
    if socket.assigns.expanded == uuid do
      {:noreply, assign(socket, expanded: nil, grants: [])}
    else
      {:noreply, assign(socket, expanded: uuid, grants: Mailboxes.list_grants(uuid))}
    end
  end

  def handle_event("grant", %{"user_uuid" => target, "access" => access}, socket) do
    with {:ok, mailbox} <- expanded_mailbox(socket),
         {:ok, _grant} <-
           Mailboxes.grant_access(socket.assigns.scope, mailbox, String.trim(target), access) do
      {:noreply,
       socket
       |> assign(:grants, Mailboxes.list_grants(mailbox.uuid))
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
       |> assign(:grants, Mailboxes.list_grants(mailbox.uuid))
       |> put_flash(:info, gettext("Access revoked."))}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, Errors.message(reason))}
    end
  end

  def handle_event("archive", %{"uuid" => uuid}, socket) do
    with {:ok, mailbox} <- Mailboxes.fetch_mailbox(uuid),
         {:ok, _} <- Mailboxes.archive_mailbox(socket.assigns.scope, mailbox) do
      {:noreply,
       socket
       |> load_mailboxes()
       |> put_flash(:info, gettext("Mailbox archived."))}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, Errors.message(reason))}
    end
  end

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
          grant_form={@grant_form}
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
  attr(:grant_form, :any, required: true)

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
                    <.grant_panel grants={@grants} grant_form={@grant_form} />
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
  attr(:grant_form, :any, required: true)

  defp grant_panel(assigns) do
    ~H"""
    <div class="flex flex-col gap-3 py-2">
      <ul :if={@grants != []} class="flex flex-col gap-1">
        <li :for={grant <- @grants} class="flex items-center gap-2 text-sm">
          <code class="text-xs">{grant.user_uuid}</code>
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

      <.form for={@grant_form} phx-submit="grant" class="flex flex-wrap items-end gap-2">
        <.input
          field={@grant_form[:user_uuid]}
          type="text"
          label={gettext("User UUID")}
          class="input-sm"
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
        <button type="submit" class="btn btn-primary btn-sm">
          {gettext("Grant access")}
        </button>
      </.form>
    </div>
    """
  end
end
