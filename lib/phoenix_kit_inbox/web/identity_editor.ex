defmodule PhoenixKitInbox.Web.IdentityEditor do
  @moduledoc """
  The sending-identity list and form, shared by the two settings pages:
  `:personal` on `Web.MySettingsLive` (the user's own, on their own mail
  integrations), `:shared` on `Web.SettingsLive` (system integrations, for
  holders of `inbox.manage_shared`). A host LiveView calls `assign_editor/2`
  and routes every `"ident_*"` event to `handle_event/3`; `editor/1` renders.

  The From address is shown, never asked for: it is the integration's login.
  Every write goes through `PhoenixKitInbox.Identities` with the session
  scope, which checks it again — the choices offered here only hide what
  would be refused.
  """

  use PhoenixKitWeb, :html

  alias PhoenixKitInbox.Errors
  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Schemas.Identity

  @doc "Loads the identities of `kind` the scope may manage, and the form's choices."
  @spec assign_editor(Phoenix.LiveView.Socket.t(), :personal | :shared) ::
          Phoenix.LiveView.Socket.t()
  def assign_editor(socket, kind) do
    scope = socket.assigns.scope

    {identities, mailboxes} =
      case kind do
        :personal ->
          {Identities.list_personal(scope), []}

        :shared ->
          shared =
            Mailboxes.list_shared_mailboxes() |> Enum.filter(&(&1.status == "active"))

          {Identities.list_shared(scope), shared}
      end

    socket
    |> assign(:ident_kind, kind)
    |> assign(:identities, identities)
    # Loaded when "Add sender" is pressed: each choice asks core for the
    # connection's credentials, which a page load should not do.
    |> assign(:ident_integrations, [])
    |> assign(:ident_mailboxes, mailboxes)
    |> assign(:ident_form, nil)
    |> assign_new(:ident_problems, fn -> %{} end)
  end

  @doc "Handles the editor's `\"ident_*\"` events."
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("ident_new", _params, socket) do
    case Identities.mail_integrations(socket.assigns.scope, socket.assigns.ident_kind) do
      [] ->
        {:noreply,
         Phoenix.LiveView.put_flash(
           socket,
           :error,
           gettext_str("There is no mail connection with a login address to send from yet.")
         )}

      integrations ->
        {:noreply,
         socket
         |> assign(:ident_integrations, integrations)
         |> assign(
           :ident_form,
           to_form(
             %{"label" => "", "from_name" => "", "integration_uuid" => "", "mailbox_uuid" => ""},
             as: :identity
           )
         )}
    end
  end

  def handle_event("ident_cancel", _params, socket) do
    {:noreply, assign(socket, :ident_form, nil)}
  end

  def handle_event("ident_save", %{"identity" => params}, socket) do
    result =
      case socket.assigns.ident_kind do
        :personal -> Identities.create_personal(socket.assigns.scope, params)
        :shared -> Identities.create_shared(socket.assigns.scope, params)
      end

    case result do
      {:ok, _identity} ->
        {:noreply,
         socket
         |> assign_editor(socket.assigns.ident_kind)
         |> Phoenix.LiveView.put_flash(:info, gettext_str("Sender saved."))}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:ident_form, to_form(params, as: :identity))
         |> assign(
           :ident_integrations,
           Identities.mail_integrations(socket.assigns.scope, socket.assigns.ident_kind)
         )
         |> Phoenix.LiveView.put_flash(:error, Errors.message(reason))}
    end
  end

  # The list shows the stored status; "Check" asks the integration again and
  # records the outcome (`Identities.recheck/2` checks who may).
  def handle_event("ident_check", %{"uuid" => uuid}, socket) do
    case Identities.recheck(socket.assigns.scope, %Identity{uuid: uuid}) do
      {:ok, outcome} ->
        problems = Map.put(socket.assigns.ident_problems, uuid, outcome)

        {:noreply,
         socket
         |> assign(:ident_problems, problems)
         |> assign_editor(socket.assigns.ident_kind)}

      {:error, reason} ->
        {:noreply, Phoenix.LiveView.put_flash(socket, :error, Errors.message(reason))}
    end
  end

  def handle_event("ident_delete", %{"uuid" => uuid}, socket) do
    case Identities.delete_identity(socket.assigns.scope, %Identity{uuid: uuid}) do
      :ok ->
        {:noreply,
         socket
         |> assign_editor(socket.assigns.ident_kind)
         |> Phoenix.LiveView.put_flash(:info, gettext_str("Sender deleted."))}

      {:error, reason} ->
        {:noreply, Phoenix.LiveView.put_flash(socket, :error, Errors.message(reason))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  attr(:id, :string, required: true)
  attr(:kind, :atom, required: true)
  attr(:identities, :list, required: true)
  attr(:integrations, :list, required: true)
  attr(:mailboxes, :list, default: [])
  attr(:problems, :map, default: %{})
  attr(:form, :any, required: true)

  @doc "The identity list with its add form."
  def editor(assigns) do
    assigns =
      assign(assigns, :mailbox_names, Map.new(assigns.mailboxes, &{&1.uuid, &1.name}))

    ~H"""
    <div id={@id} class="flex flex-col gap-3">
      <p :if={@identities == []} class="text-sm text-base-content/60">
        {gettext_str("No senders yet.")}
      </p>

      <div
        :for={entry <- @identities}
        id={"identity-#{entry.identity.uuid}"}
        class="rounded-box border border-base-300 p-3 flex flex-wrap items-center gap-2"
      >
        <span class="font-medium">{entry.identity.label}</span>
        <span :if={entry.from_address} class="text-sm text-base-content/70">
          &lt;{entry.from_address}&gt;
        </span>
        <span :if={@kind == :shared} class="badge badge-ghost badge-sm">
          {bound_to(entry.identity, @mailbox_names)}
        </span>
        <span :if={entry.identity.status == "broken"} class="badge badge-error badge-sm gap-1">
          <.icon name="hero-exclamation-triangle" class="w-3 h-3" />
          {gettext_str("Broken")}
        </span>
        <span :if={entry.identity.status == "broken"} class="text-xs text-error w-full">
          {problem_text(Map.get(@problems, entry.identity.uuid))}
        </span>
        <button
          type="button"
          class="btn btn-ghost btn-xs ml-auto"
          phx-click="ident_check"
          phx-value-uuid={entry.identity.uuid}
        >
          <.icon name="hero-arrow-path" class="w-4 h-4" /> {gettext_str("Check")}
        </button>
        <button
          type="button"
          class="btn btn-ghost btn-xs text-error"
          phx-click="ident_delete"
          phx-value-uuid={entry.identity.uuid}
          data-confirm={gettext_str("Delete this sender?")}
        >
          <.icon name="hero-trash" class="w-4 h-4" /> {gettext_str("Delete")}
        </button>
      </div>

      <.form
        :if={@form}
        for={@form}
        id={"#{@id}-form"}
        phx-submit="ident_save"
        class="rounded-box border border-base-300 p-3 flex flex-col gap-2"
      >
        <.input field={@form[:label]} type="text" label={gettext_str("Name")} />
        <.input
          field={@form[:from_name]}
          type="text"
          label={gettext_str("Name shown to recipients")}
        />
        <.select
          field={@form[:integration_uuid]}
          label={gettext_str("Mail connection (its login is the From address)")}
          options={Enum.map(@integrations, &{"#{&1.name} <#{&1.from_address}>", &1.uuid})}
        />
        <.select
          :if={@kind == :shared}
          field={@form[:mailbox_uuid]}
          label={gettext_str("Shared mailbox")}
          options={[
            {gettext_str("None — the common sender for personal mailboxes"), ""}
            | Enum.map(@mailboxes, &{&1.name, &1.uuid})
          ]}
        />
        <div class="flex justify-end gap-2">
          <button type="button" class="btn btn-ghost btn-sm" phx-click="ident_cancel">
            {gettext_str("Cancel")}
          </button>
          <button type="submit" class="btn btn-primary btn-sm">{gettext_str("Save")}</button>
        </div>
      </.form>

      <div :if={is_nil(@form)}>
        <button type="button" class="btn btn-ghost btn-sm" phx-click="ident_new">
          <.icon name="hero-plus" class="w-4 h-4" /> {gettext_str("Add sender")}
        </button>
      </div>
    </div>
    """
  end

  defp bound_to(%Identity{mailbox_uuid: nil}, _names),
    do: gettext_str("Common sender for personal mailboxes")

  defp bound_to(%Identity{mailbox_uuid: uuid}, names), do: Map.get(names, uuid, "—")

  defp problem_text({:error, problem}), do: Errors.message({:integration_unusable, problem})

  defp problem_text(_),
    do:
      gettext_str(
        "Its mail connection is missing, disconnected or no longer usable. Fix it, then check again."
      )

  defp gettext_str(msgid), do: Gettext.gettext(PhoenixKitWeb.Gettext, msgid)
end
