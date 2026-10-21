defmodule PhoenixKitInbox.Web.SettingsLive do
  @moduledoc """
  Inbox settings for holders of `inbox.manage_shared` (`/admin/inbox/settings`):

    * **Shared senders** — identities on system mail integrations, each bound
      to a shared mailbox or to none (the common sender for personal
      mailboxes), with their From address and a "Broken" mark when the
      integration no longer works (`Web.IdentityEditor`)
    * **Signatures of shared mailboxes** the viewer administers
      (`Web.SignatureEditor`)

  Without `inbox.manage_shared` the page says so and renders no form; the
  contexts refuse a forged event anyway. A user's own signatures, Reply-To
  and personal senders are on `Web.MySettingsLive`.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitInbox.Errors
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Paths
  alias PhoenixKitInbox.Web.IdentityEditor
  alias PhoenixKitInbox.Web.SignatureEditor

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    module_access = scope && Scope.has_module_access?(scope, "inbox")
    manage = module_access && Mailboxes.can_manage_shared?(scope)

    socket =
      socket
      |> assign(:page_title, gettext_str("Inbox settings"))
      |> assign(:scope, scope)
      |> assign(:module_access, module_access)
      |> assign(:can_manage_shared, manage)
      |> assign(:admin_mailboxes, if(manage, do: admin_mailboxes(scope), else: []))
      |> load(manage)

    {:ok, socket}
  end

  # Shared mailboxes whose signatures the viewer may write: "admin" on them.
  defp admin_mailboxes(scope) do
    {:ok, user_uuid} = Mailboxes.scope_user_uuid(scope)

    Mailboxes.list_shared_mailboxes()
    |> Enum.filter(&(&1.status == "active" and Mailboxes.access_level(&1, user_uuid) == "admin"))
  end

  defp load(socket, false) do
    socket
    |> assign(:identities, [])
    |> assign(:ident_integrations, [])
    |> assign(:ident_mailboxes, [])
    |> assign(:ident_form, nil)
    |> assign(:ident_problems, %{})
    |> SignatureEditor.assign_editor(nil)
  end

  defp load(socket, true) do
    socket
    |> IdentityEditor.assign_editor(:shared)
    |> SignatureEditor.assign_editor(List.first(socket.assigns.admin_mailboxes))
  end

  # ── Events ──────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("sig_mailbox", %{"mailbox" => uuid}, socket) do
    case Enum.find(socket.assigns.admin_mailboxes, &(&1.uuid == uuid)) do
      nil -> {:noreply, socket}
      mailbox -> {:noreply, SignatureEditor.assign_editor(socket, mailbox)}
    end
  end

  def handle_event("sig_" <> _ = event, params, socket),
    do: SignatureEditor.handle_event(event, params, socket)

  def handle_event(
        "ident_" <> _ = event,
        params,
        %{assigns: %{can_manage_shared: true}} = socket
      ),
      do: IdentityEditor.handle_event(event, params, socket)

  def handle_event("ident_" <> _, _params, socket),
    do: {:noreply, put_flash(socket, :error, Errors.message(:forbidden))}

  # ── Render ──────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div id="inbox-settings" class="flex flex-col px-4 py-6 gap-4">
      <div :if={not @module_access} class="alert alert-warning">
        <.icon name="hero-lock-closed" class="w-5 h-5" />
        <span>{gettext_str("You don't have permission to use Inbox.")}</span>
      </div>

      <div :if={@module_access and not @can_manage_shared} class="alert alert-info">
        <.icon name="hero-information-circle" class="w-5 h-5" />
        <span>
          {gettext_str("Shared senders and signatures are managed by holders of “Manage shared mailboxes”.")}
        </span>
        <.link navigate={Paths.my_settings()} class="link">{gettext_str("Your mail settings")}</.link>
      </div>

      <section :if={@can_manage_shared} class="card bg-base-100 shadow max-w-4xl">
        <div class="card-body gap-3">
          <h2 class="card-title text-base">{gettext_str("Shared senders")}</h2>
          <p class="text-sm text-base-content/60">
            {gettext_str(
              "A system mail connection to send from. Bound to a shared mailbox, everyone who writes to it may use it; bound to none, it is the common sender for personal mailboxes, for those allowed to write to external addresses."
            )}
          </p>
          <IdentityEditor.editor
            id="shared-identities"
            kind={:shared}
            identities={@identities}
            integrations={@ident_integrations}
            mailboxes={@ident_mailboxes}
            problems={@ident_problems}
            form={@ident_form}
          />
        </div>
      </section>

      <section :if={@can_manage_shared} class="card bg-base-100 shadow max-w-4xl">
        <div class="card-body gap-3">
          <h2 class="card-title text-base">{gettext_str("Signatures of shared mailboxes")}</h2>

          <p :if={@admin_mailboxes == []} class="text-sm text-base-content/60">
            {gettext_str("You don't administer any shared mailbox.")}
          </p>

          <form
            :if={@admin_mailboxes != []}
            id="signature-mailbox-form"
            phx-change="sig_mailbox"
            class="flex items-center gap-2"
          >
            <span class="text-sm">{gettext_str("Mailbox")}</span>
            <.select
              name="mailbox"
              value={@sig_mailbox && @sig_mailbox.uuid}
              options={Enum.map(@admin_mailboxes, &{&1.name, &1.uuid})}
              class="select-sm"
            />
          </form>

          <SignatureEditor.editor
            :if={@sig_mailbox}
            id="shared-signatures"
            signatures={@signatures}
            editing={@sig_editing}
            form={@sig_form}
          />
        </div>
      </section>
    </div>
    """
  end

  defp gettext_str(msgid), do: Gettext.gettext(PhoenixKitWeb.Gettext, msgid)
end
