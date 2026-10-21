defmodule PhoenixKitInbox.Web.MySettingsLive do
  @moduledoc """
  "Mail settings" — the signed-in user's own Inbox settings, reached from
  the avatar menu (`PhoenixKitInbox.user_dashboard_tabs/0`). Not an admin
  page: core routes it under `/dashboard/inbox-settings` in its
  authenticated session, so it checks access itself and draws its own
  layout.

    * **Signatures** of the user's personal mailbox (`Web.SignatureEditor`)
    * **Reply-To** their personal mailbox defaults to
      (`Identities.set_default_reply_to/2`)
    * **Senders** — personal identities on their own mail integrations
      (`Web.IdentityEditor`), with a link to core's personal integrations
      page for those who may add one

  Everything is checked again in the contexts with the session scope.
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
  alias PhoenixKitInbox.Web.SignatureEditor

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    access = PhoenixKitInbox.user_menu?(scope)

    socket =
      socket
      |> assign(:page_title, gettext("Mail settings"))
      |> assign(:project_title, project_title())
      |> assign(:url_path, Paths.my_settings())
      |> assign(:scope, scope)
      |> assign(:module_access, access)
      |> assign(:integrations_access, Scope.has_module_access?(scope, "integrations"))
      |> load(access && personal_mailbox(scope))

    {:ok, socket}
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

  # ── Render ──────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={@scope}
      page_title={@page_title}
      current_path={@url_path}
      project_title={@project_title}
      current_locale={assigns[:current_locale]}
    >
      <div id="inbox-my-settings" class="flex flex-col px-4 py-6 gap-4">
        <div :if={not @module_access} class="alert alert-warning">
          <.icon name="hero-lock-closed" class="w-5 h-5" />
          <span>{gettext("You don't have permission to use Inbox.")}</span>
        </div>

        <div :if={@module_access} class="flex flex-wrap gap-2">
          <.link navigate={Paths.inbox()} id="open-inbox" class="btn btn-primary btn-sm">
            <.icon name="hero-envelope" class="w-4 h-4" /> {gettext("Open Inbox")}
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
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
