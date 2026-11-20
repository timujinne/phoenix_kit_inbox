defmodule PhoenixKitInbox.Web.MySettingsLive do
  @moduledoc """
  "Mail settings" — the signed-in user's own Inbox settings, reached from
  the avatar menu (`PhoenixKitInbox.user_dashboard_tabs/0`). Not an admin
  page: core routes it under `/dashboard/inbox-settings` in its
  authenticated session, so it checks access itself and draws the user
  dashboard's shell (`PhoenixKitWeb.Layouts.dashboard`) around itself.

    * **Signatures** of the user's personal mailbox (`Web.SignatureEditor`)
    * **Reply-To** their personal mailbox defaults to
      (`Identities.set_default_reply_to/2`)
    * **Senders** — personal identities on their own mail integrations
      (`Web.IdentityEditor`), with a link to core's personal integrations
      page for those who may add one
    * a link to the **shared mail** page (`Web.SettingsLive`) for holders of
      `inbox.manage_shared`

  Everything is checked again in the contexts with the session scope. The
  page follows access changes while open (core's scope refresh,
  `phoenix_kit_scope_changed/1`, and Inbox's own access events): core moves
  nobody off a page outside the admin area for a lost module permission, so
  a user who lost Inbox is sent to the user dashboard from here — unless
  they lost the admin area altogether, when core moves them itself.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitInbox.Gettext

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitInbox.Errors
  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Paths
  alias PhoenixKitInbox.Web.IdentityEditor
  alias PhoenixKitInbox.Web.ScopeRefresh
  alias PhoenixKitInbox.Web.SignatureEditor

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("Mail settings"))
      |> assign(:project_title, project_title())
      |> assign(:url_path, Paths.my_settings())
      |> ScopeRefresh.assign_scope()
      |> assign_gates()
      |> ScopeRefresh.subscribe([:user])

    {:ok,
     load(socket, if(socket.assigns.module_access, do: personal_mailbox(socket.assigns.scope)))}
  end

  @doc false
  # Core's scope refresh: the scope changed under the page. The gates again;
  # losing Inbox leaves the page, gaining it loads it, and otherwise only the
  # Reply-To choices, which follow the grants, are read again — an open
  # editor form stays.
  def phoenix_kit_scope_changed(socket) do
    had_access? = socket.assigns.module_access
    old_scope = socket.assigns.scope
    socket = socket |> ScopeRefresh.assign_scope() |> assign_gates()

    cond do
      not socket.assigns.module_access and core_evicts?(old_scope, socket.assigns.scope) ->
        load(socket, nil)

      not socket.assigns.module_access ->
        socket
        |> load(nil)
        |> put_flash(:error, gettext("You no longer have access to Inbox."))
        |> push_navigate(to: Paths.dashboard())

      not had_access? ->
        load(socket, personal_mailbox(socket.assigns.scope))

      true ->
        reload_reply_to(socket)
    end
  end

  # Core moves whoever lost the admin area off ANY page, this one included
  # (`scope_refresh_decision/4`, `:evict_admin_area`), right after this
  # callback; a second navigation from here would crash the socket.
  defp core_evicts?(old_scope, new_scope),
    do: Scope.can_access_admin_area?(old_scope) and not Scope.can_access_admin_area?(new_scope)

  defp assign_gates(socket) do
    scope = socket.assigns.scope
    access = PhoenixKitInbox.user_menu?(scope)

    socket
    |> assign(:module_access, access)
    |> assign(:integrations_access, Scope.has_module_access?(scope, "integrations"))
    |> assign(:can_manage_shared, access && Mailboxes.can_manage_shared?(scope))
  end

  defp reload_reply_to(%{assigns: %{mailbox: nil}} = socket), do: socket

  defp reload_reply_to(socket) do
    assign(
      socket,
      :reply_to_options,
      Identities.reply_to_options(socket.assigns.scope, socket.assigns.mailbox)
    )
  end

  defp personal_mailbox(%Scope{user: user}) do
    case Mailboxes.ensure_user_mailbox(user) do
      {:ok, mailbox} -> mailbox
      _ -> nil
    end
  end

  defp load(socket, nil) do
    socket
    |> assign(:mailbox, nil)
    |> assign(:reply_to_options, [])
    |> SignatureEditor.assign_editor(nil)
    |> assign(:identities, [])
    |> assign(:ident_integrations, [])
    |> assign(:ident_form, nil)
    |> assign(:ident_problems, %{})
  end

  defp load(socket, mailbox) do
    socket
    |> assign(:mailbox, mailbox)
    |> assign(:reply_to_options, Identities.reply_to_options(socket.assigns.scope, mailbox))
    |> SignatureEditor.assign_editor(mailbox)
    |> IdentityEditor.assign_editor(:personal)
  end

  defp project_title do
    Settings.get_project_title()
  rescue
    _ -> nil
  end

  # ── Events ──────────────────────────────────────────────────────────────────

  @impl true
  def handle_event(_event, _params, %{assigns: %{module_access: false}} = socket),
    do: {:noreply, put_flash(socket, :error, Errors.message(:forbidden))}

  def handle_event("sig_" <> _ = event, params, socket),
    do: SignatureEditor.handle_event(event, params, socket)

  def handle_event("ident_" <> _ = event, params, socket),
    do: IdentityEditor.handle_event(event, params, socket)

  def handle_event("save_reply_to", %{"reply_to" => address}, socket) do
    case Identities.set_default_reply_to(socket.assigns.scope, address) do
      {:ok, mailbox} ->
        {:noreply,
         socket
         |> load(mailbox)
         |> put_flash(:info, gettext("Reply-To saved."))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Errors.message(reason))}
    end
  end

  # A grant given or taken changes the Reply-To choices.
  @impl true
  def handle_info({:inbox_access_changed, _what}, socket),
    do: {:noreply, reload_reply_to(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # ── Render ──────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- The user dashboard's own shell (header, sidebar, avatar menu), as
         core's and the other modules' `/dashboard/…` pages draw it.
         `LayoutWrapper.app_layout` gives the admin shell to admin paths only:
         for this path it handed the page to the host's layout, and a host
         whose layout is a bare `<main>` showed it with no header and no
         sidebar. The scope is the page's own (`ScopeRefresh`), which follows
         access changes. --%>
    <PhoenixKitWeb.Layouts.dashboard {dashboard_assigns(assigns)} phoenix_kit_current_scope={@scope}>
      <div id="inbox-my-settings" class="flex flex-col px-4 py-6 gap-4">
        <div :if={not @module_access} class="alert alert-warning">
          <.icon name="hero-lock-closed" class="w-5 h-5" />
          <span>{gettext("You don't have permission to use Inbox.")}</span>
        </div>

        <div :if={@module_access} class="flex flex-wrap gap-2">
          <.link navigate={Paths.inbox()} id="open-inbox" class="btn btn-primary btn-sm">
            <.icon name="hero-envelope" class="w-4 h-4" /> {gettext("Open Inbox")}
          </.link>
          <.link
            :if={@can_manage_shared}
            navigate={Paths.settings()}
            id="manage-shared-mail"
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-cog-6-tooth" class="w-4 h-4" /> {gettext("Manage shared mail")}
          </.link>
        </div>

        <section :if={@module_access and @mailbox} class="card bg-base-100 shadow max-w-4xl">
          <div class="card-body gap-3">
            <h2 class="card-title text-base">{gettext("Signatures")}</h2>
            <p class="text-sm text-base-content/60">
              {gettext(
                "Added at the end of a message you write from your personal mailbox, after a “-- ” line."
              )}
            </p>
            <SignatureEditor.editor
              id="my-signatures"
              signatures={@signatures}
              editing={@sig_editing}
              form={@sig_form}
            />
          </div>
        </section>

        <section
          :if={@module_access and @reply_to_options != []}
          class="card bg-base-100 shadow max-w-4xl"
        >
          <div class="card-body gap-3">
            <h2 class="card-title text-base">{gettext("Reply-To")}</h2>
            <p class="text-sm text-base-content/60">
              {gettext(
                "Where replies to your messages go by default: your email, or a shared mailbox you write to."
              )}
            </p>
            <.form
              for={to_form(%{})}
              id="reply-to-form"
              phx-submit="save_reply_to"
              class="flex flex-wrap items-end gap-2"
            >
              <.select
                name="reply_to"
                value={Identities.default_reply_to(@reply_to_options)}
                options={Enum.map(@reply_to_options, &{&1.label, &1.address})}
                class="select-sm"
              />
              <button type="submit" class="btn btn-primary btn-sm">{gettext("Save")}</button>
            </.form>
          </div>
        </section>

        <section :if={@module_access and @mailbox} class="card bg-base-100 shadow max-w-4xl">
          <div class="card-body gap-3">
            <h2 class="card-title text-base">{gettext("Senders")}</h2>
            <p class="text-sm text-base-content/60">
              {gettext(
                "Send from your own mail connection. The From address is the connection's login."
              )}
            </p>
            <IdentityEditor.editor
              id="my-identities"
              kind={:personal}
              identities={@identities}
              integrations={@ident_integrations}
              problems={@ident_problems}
              form={@ident_form}
            />
            <.link
              :if={@integrations_access}
              navigate={Paths.my_integrations()}
              id="my-integrations-link"
              class="link link-primary text-sm"
            >
              {gettext("Manage your mail connections")}
            </.link>
          </div>
        </section>
      </div>
    </PhoenixKitWeb.Layouts.dashboard>
    """
  end
end
