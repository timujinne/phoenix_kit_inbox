defmodule PhoenixKitInbox.Web.SettingsLive do
  @moduledoc """
  "Shared mail" — Inbox settings for holders of `inbox.manage_shared`
  (`/admin/settings/inbox`, a page of core's Settings section): identities
  on system mail integrations that people send *as* (nobody reads them
  here), added, changed and deleted here, each open to the roles ticked
  (Owner always); one bound to a shared mailbox through the API is listed by
  its mailbox. With their From address and a "Broken" mark when the
  integration no longer works (`Web.IdentityEditor`).

  Without `inbox.manage_shared` the page says so and renders no form; the
  contexts refuse a forged event anyway. A shared mailbox's signatures are
  on `Web.MailboxesLive`, by the mailbox; a user's own signatures, Reply-To
  and personal senders are on `Web.MySettingsLive`.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitInbox.Gettext

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitInbox.Errors
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Paths
  alias PhoenixKitInbox.Web.IdentityEditor
  alias PhoenixKitInbox.Web.ScopeRefresh

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("Mail"))
      |> ScopeRefresh.assign_scope()
      |> assign_gates()
      |> assign(:internal_enabled, PhoenixKitInbox.internal_enabled?())
      |> assign(:toggle_nonce, 0)

    {:ok, load(socket, socket.assigns.can_manage_shared)}
  end

  @doc false
  # Core's scope refresh: the scope changed under the page. The editor is
  # loaded again when the gate changed; while it holds, an open form stays —
  # every write checks the new scope anyway.
  def phoenix_kit_scope_changed(socket) do
    manage = socket.assigns.can_manage_shared
    socket = socket |> ScopeRefresh.assign_scope() |> assign_gates()

    case socket.assigns.can_manage_shared do
      ^manage -> socket
      now -> load(socket, now)
    end
  end

  defp assign_gates(socket) do
    scope = socket.assigns.scope
    module_access = Scope.can?(scope, "inbox")

    socket
    |> assign(:module_access, module_access)
    |> assign(:can_manage_shared, module_access && Mailboxes.can_manage_shared?(scope))
  end

  defp load(socket, false) do
    socket
    |> assign(:identities, [])
    |> assign(:ident_integrations, [])
    |> assign(:ident_mailboxes, [])
    |> assign(:ident_roles, [])
    |> assign(:ident_form, nil)
    |> assign(:ident_editing, nil)
    |> assign(:ident_problems, %{})
  end

  defp load(socket, true), do: IdentityEditor.assign_editor(socket, :shared)

  # ── Events ──────────────────────────────────────────────────────────────────

  @impl true
  # The state to set is the one clicked on, not the opposite of what is read:
  # a second admin or a double click sets it twice, it does not flip it back.
  def handle_event(
        "toggle_internal",
        %{"enabled" => enabled},
        %{assigns: %{can_manage_shared: true}} = socket
      )
      when enabled in ["true", "false"] do
    enabled = enabled == "true"

    case PhoenixKitInbox.set_internal_enabled(enabled) do
      {:ok, _setting} ->
        {:noreply, assign(socket, :internal_enabled, enabled)}

      _failed ->
        # The nonce renews the toggle's element: the state it shows is the
        # old one again, which a browser that already flipped it would not
        # be told by an unchanged assign.
        {:noreply,
         socket
         |> assign(:internal_enabled, PhoenixKitInbox.internal_enabled?())
         |> update(:toggle_nonce, &(&1 + 1))
         |> put_flash(:error, gettext("The setting could not be saved. Try again."))}
    end
  end

  def handle_event("toggle_internal", _params, %{assigns: %{can_manage_shared: true}} = socket),
    do: {:noreply, socket}

  def handle_event("toggle_internal", _params, socket),
    do: {:noreply, put_flash(socket, :error, Errors.message(:forbidden))}

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
        <span>{gettext("You don't have permission to use Inbox.")}</span>
      </div>

      <div :if={@module_access and not @can_manage_shared} class="alert alert-info">
        <.icon name="hero-information-circle" class="w-5 h-5" />
        <span>
          {gettext("Shared mail is managed by holders of “Manage shared mailboxes”.")}
        </span>
        <.link navigate={Paths.my_settings()} class="link">{gettext("Your mail settings")}</.link>
      </div>

      <section :if={@can_manage_shared} id="internal-mail" class="card bg-base-100 shadow max-w-4xl">
        <div class="card-body gap-3">
          <h2 class="card-title text-base">{gettext("Mail inside the application")}</h2>
          <label
            id={"internal-mail-label-#{@toggle_nonce}"}
            class="flex cursor-pointer items-start gap-3"
          >
            <input
              id="internal-mail-toggle"
              type="checkbox"
              class="toggle toggle-primary"
              checked={@internal_enabled}
              phx-click="toggle_internal"
              phx-value-enabled={to_string(not @internal_enabled)}
            />
            <span class="text-sm">
              {gettext(
                "Deliver mail between people and to shared mailboxes inside the application. When this is off, a colleague is written to by their email address and “@name” addresses are refused; letters already delivered stay readable."
              )}
            </span>
          </label>
        </div>
      </section>

      <section :if={@can_manage_shared} class="card bg-base-100 shadow max-w-4xl">
        <div class="card-body gap-3">
          <h2 class="card-title text-base">{gettext("Shared mail")}</h2>
          <p class="text-sm text-base-content/60">
            {gettext(
              "A system mail connection people send from their personal mailbox, as “their name | the mail's name”. Each one is open to the roles ticked; the Owner always."
            )}
          </p>
          <IdentityEditor.editor
            id="shared-identities"
            kind={:shared}
            identities={@identities}
            integrations={@ident_integrations}
            mailboxes={@ident_mailboxes}
            roles={@ident_roles}
            editing={@ident_editing}
            problems={@ident_problems}
            form={@ident_form}
          />
        </div>
      </section>

    </div>
    """
  end
end
