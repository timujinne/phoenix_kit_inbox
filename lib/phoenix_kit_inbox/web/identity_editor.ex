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
  would be refused. Only the form's own fields are passed on
  (`@fields`): a forged `mailbox_uuid`, say, is dropped here.

  `:shared` is the "shared mail" list: people send *as* it, nobody reads it
  here. It is never bound to a mailbox from this form; each one is open to
  the roles ticked (`Identities.role_choices/1`; Owner always). A sender
  bound to a shared mailbox through the API is listed by its mailbox, and
  its form has no roles. A shared one can be changed (`"ident_edit"`).
  """

  use PhoenixKitWeb, :html
  use Gettext, backend: PhoenixKitInbox.Gettext

  alias PhoenixKitInbox.Errors
  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Schemas.Identity

  @fields %{
    personal: ~w(label from_name integration_uuid),
    shared: ~w(label from_name integration_uuid role_uuids)
  }

  @doc "Loads the identities of `kind` the scope may manage, and the form's choices."
  @spec assign_editor(Phoenix.LiveView.Socket.t(), :personal | :shared) ::
          Phoenix.LiveView.Socket.t()
  def assign_editor(socket, kind) do
    scope = socket.assigns.scope

    {identities, mailboxes} =
      case kind do
        :personal ->
          {Identities.list_personal(scope), []}

        # Names of the mailboxes the API bound senders to.
        :shared ->
          {Identities.list_shared(scope), Mailboxes.list_shared_mailboxes()}
      end

    socket
    |> assign(:ident_kind, kind)
    |> assign(:identities, identities)
    # Loaded when "Add sender" is pressed: each choice asks core for the
    # connection's credentials, which a page load should not do.
    |> assign(:ident_integrations, [])
    |> assign(:ident_mailboxes, mailboxes)
    |> assign(:ident_roles, [])
    |> assign(:ident_form, nil)
    |> assign(:ident_editing, nil)
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
           gettext("There is no mail connection with a login address to send from yet.")
         )}

      integrations ->
        roles = role_choices(socket)

        # A new shared mail starts open to the roles that give the right to
        # write externally — whom it would have served before it had roles.
        params = %{
          "label" => "",
          "from_name" => "",
          "integration_uuid" => "",
          "role_uuids" => for(%{sends_external: true, uuid: uuid} <- roles, do: uuid)
        }

        {:noreply,
         socket
         |> assign(:ident_integrations, integrations)
         |> assign(:ident_roles, roles)
         |> assign(:ident_editing, nil)
         |> assign(:ident_form, to_form(params, as: :identity))}
    end
  end

  # Only a listed shared one: the list is what the scope may manage.
  def handle_event("ident_edit", %{"uuid" => uuid}, %{assigns: %{ident_kind: :shared}} = socket) do
    case Enum.find(socket.assigns.identities, &(&1.identity.uuid == uuid)) do
      nil ->
        {:noreply, Phoenix.LiveView.put_flash(socket, :error, Errors.message(:not_found))}

      %{identity: identity} = entry ->
        params = %{
          "label" => identity.label,
          "from_name" => identity.from_name || "",
          "integration_uuid" => identity.integration_uuid,
          "role_uuids" => Enum.map(Map.get(entry, :roles, []), & &1.uuid)
        }

        {:noreply,
         socket
         |> assign(
           :ident_integrations,
           Identities.mail_integrations(socket.assigns.scope, :shared)
         )
         |> assign(:ident_roles, role_choices(socket))
         |> assign(:ident_editing, identity)
         |> assign(:ident_form, to_form(params, as: :identity))}
    end
  end

  def handle_event("ident_cancel", _params, socket) do
    {:noreply, socket |> assign(:ident_form, nil) |> assign(:ident_editing, nil)}
  end

  def handle_event("ident_save", %{"identity" => params}, socket) do
    params = Map.take(params, Map.fetch!(@fields, socket.assigns.ident_kind))

    case save(socket, params) do
      {:ok, _identity} ->
        {:noreply,
         socket
         |> assign_editor(socket.assigns.ident_kind)
         |> Phoenix.LiveView.put_flash(:info, gettext("Sender saved."))}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:ident_form, to_form(params, as: :identity))
         |> assign(
           :ident_integrations,
           Identities.mail_integrations(socket.assigns.scope, socket.assigns.ident_kind)
         )
         |> assign(:ident_roles, role_choices(socket))
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
         |> Phoenix.LiveView.put_flash(:info, gettext("Sender deleted."))}

      {:error, reason} ->
        {:noreply, Phoenix.LiveView.put_flash(socket, :error, Errors.message(reason))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp save(%{assigns: %{ident_editing: %Identity{} = identity}} = socket, params),
    do: Identities.update_identity(socket.assigns.scope, identity, params)

  defp save(%{assigns: %{ident_kind: :personal}} = socket, params),
    do: Identities.create_personal(socket.assigns.scope, params)

  defp save(%{assigns: %{ident_kind: :shared}} = socket, params),
    do: Identities.create_shared(socket.assigns.scope, params)

  defp role_choices(%{assigns: %{ident_kind: :shared, scope: scope}}),
    do: Identities.role_choices(scope)

  defp role_choices(_socket), do: []

  attr(:id, :string, required: true)
  attr(:kind, :atom, required: true)
  attr(:identities, :list, required: true)
  attr(:integrations, :list, required: true)
  attr(:mailboxes, :list, default: [])
  attr(:roles, :list, default: [])
  attr(:editing, :any, default: nil)
  attr(:problems, :map, default: %{})
  attr(:form, :any, required: true)

  @doc "The identity list with its add and edit form."
  def editor(assigns) do
    assigns =
      assigns
      |> assign(:mailbox_names, Map.new(assigns.mailboxes, &{&1.uuid, &1.name}))
      |> assign(
        :bound_edit?,
        match?(%Identity{mailbox_uuid: bound} when is_binary(bound), assigns.editing)
      )
      |> assign(:ticked, ticked(assigns.form))
      |> assign(:integration_prompt, integration_prompt(assigns.editing, assigns.integrations))

    ~H"""
    <div id={@id} class="flex flex-col gap-3">
      <p :if={@identities == []} class="text-sm text-base-content/60">
        {gettext("No senders yet.")}
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
        <span
          :if={@kind == :shared and entry.identity.from_name not in [nil, ""]}
          class="text-sm text-base-content/70"
        >
          {gettext("Shown as “%{name}”", name: entry.identity.from_name)}
        </span>
        <span :if={entry.identity.status == "broken"} class="badge badge-error badge-sm gap-1">
          <.icon name="hero-exclamation-triangle" class="w-3 h-3" />
          {gettext("Broken")}
        </span>
        <span class="ml-auto flex gap-1">
          <button
            :if={@kind == :shared}
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click="ident_edit"
            phx-value-uuid={entry.identity.uuid}
          >
            <.icon name="hero-pencil-square" class="w-4 h-4" /> {gettext("Edit")}
          </button>
          <button
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click="ident_check"
            phx-value-uuid={entry.identity.uuid}
          >
            <.icon name="hero-arrow-path" class="w-4 h-4" /> {gettext("Check")}
          </button>
          <button
            type="button"
            class="btn btn-ghost btn-xs text-error"
            phx-click="ident_delete"
            phx-value-uuid={entry.identity.uuid}
            data-confirm={gettext("Delete this sender?")}
          >
            <.icon name="hero-trash" class="w-4 h-4" /> {gettext("Delete")}
          </button>
        </span>
        <span
          :if={@kind == :shared}
          id={"identity-#{entry.identity.uuid}-roles"}
          class="text-xs text-base-content/70 w-full"
        >
          {open_to(entry, @mailbox_names)}
        </span>
        <span :if={entry.identity.status == "broken"} class="text-xs text-error w-full">
          {problem_text(Map.get(@problems, entry.identity.uuid))}
        </span>
      </div>

      <.form
        :if={@form}
        for={@form}
        id={"#{@id}-form"}
        phx-submit="ident_save"
        class="rounded-box border border-base-300 p-3 flex flex-col gap-2"
      >
        <.input field={@form[:label]} type="text" label={gettext("Name")} />
        <.input
          field={@form[:from_name]}
          type="text"
          label={gettext("Name shown to recipients")}
        />
        <.select
          field={@form[:integration_uuid]}
          label={gettext("Mail connection (its login is the From address)")}
          prompt={@integration_prompt}
          options={Enum.map(@integrations, &{"#{&1.name} <#{&1.from_address}>", &1.uuid})}
        />
        <p :if={@kind == :shared and @bound_edit?} class="text-sm text-base-content/70">
          {gettext("Used through the shared mailbox “%{name}” by everyone who writes to it.",
            name: Map.get(@mailbox_names, @editing.mailbox_uuid, "—")
          )}
        </p>
        <fieldset
          :if={@kind == :shared and not @bound_edit?}
          id={"#{@id}-roles"}
          class="fieldset flex flex-col gap-1"
        >
          <legend class="fieldset-legend">{gettext("Who may send from it")}</legend>
          <input type="hidden" name="identity[role_uuids][]" value="" />
          <span id="ident-roles-owner" class="text-sm text-base-content/70">
            {gettext("Owner — always")}
          </span>
          <label :for={role <- @roles} class="flex flex-wrap items-center gap-2 text-sm">
            <input
              type="checkbox"
              id={"ident-role-#{role.uuid}"}
              name="identity[role_uuids][]"
              value={role.uuid}
              checked={role.uuid in @ticked}
              class="checkbox checkbox-sm"
            />
            <span>{role.name}</span>
            <span
              :if={not role.sends_external}
              id={"ident-role-#{role.uuid}-no-right"}
              class="text-xs text-base-content/60"
            >
              {gettext(
                "the role has no “Send to external addresses” permission — grant it in the roles matrix"
              )}
            </span>
          </label>
          <span class="text-xs text-base-content/60">
            {gettext(
              "Sending also needs the “Send to external addresses” permission. Nobody can read this mail here."
            )}
          </span>
        </fieldset>
        <div class="flex justify-end gap-2">
          <button type="button" class="btn btn-ghost btn-sm" phx-click="ident_cancel">
            {gettext("Cancel")}
          </button>
          <button type="submit" class="btn btn-primary btn-sm">{gettext("Save")}</button>
        </div>
      </.form>

      <div :if={is_nil(@form)}>
        <button
          :if={@kind == :shared}
          type="button"
          class="btn btn-primary btn-sm"
          phx-click="ident_new"
        >
          <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add shared mail")}
        </button>
        <button
          :if={@kind == :personal}
          type="button"
          class="btn btn-ghost btn-sm"
          phx-click="ident_new"
        >
          <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add sender")}
        </button>
      </div>
    </div>
    """
  end

  # An edited identity whose stored connection is not among the working ones
  # keeps it unless another is picked: a blank choice leaves
  # `integration_uuid` alone (`Identities.update_identity/3`), where the
  # browser would otherwise select the first working one. Judged on the
  # stored row, so a refused save shows it again.
  defp integration_prompt(%Identity{integration_uuid: current}, integrations) do
    if Enum.any?(integrations, &(&1.uuid == current)),
      do: nil,
      else: gettext("Keep the current connection (it does not work now)")
  end

  defp integration_prompt(_editing, _integrations), do: nil

  defp ticked(nil), do: []

  defp ticked(form) do
    case form.params["role_uuids"] do
      uuids when is_list(uuids) -> uuids
      _ -> []
    end
  end

  defp open_to(%{identity: %Identity{mailbox_uuid: uuid}}, names) when is_binary(uuid),
    do: gettext("Through the shared mailbox “%{name}”", name: Map.get(names, uuid, "—"))

  defp open_to(%{roles: []}, _names), do: gettext("Owner only: no role is ticked")

  defp open_to(%{roles: roles}, _names),
    do: gettext("Roles: %{roles}", roles: Enum.map_join(roles, ", ", & &1.name))

  defp problem_text({:error, problem}), do: Errors.message({:integration_unusable, problem})

  defp problem_text(_),
    do:
      gettext(
        "Its mail connection is missing, disconnected or no longer usable. Fix it, then check again."
      )
end
