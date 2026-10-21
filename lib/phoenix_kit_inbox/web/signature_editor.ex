defmodule PhoenixKitInbox.Web.SignatureEditor do
  @moduledoc """
  The signature list and form of one mailbox, shared by the two settings
  pages (`Web.MySettingsLive` for the personal mailbox, `Web.SettingsLive` for
  shared ones). A host LiveView calls `assign_editor/2` and routes every
  `"sig_*"` event to `handle_event/3`; `editor/1` renders.

  The form only offers what `PhoenixKitInbox.Signatures` will accept: every
  write goes through it with the session scope, which checks the stored
  mailbox and signature again — a forged event names nothing it may change.
  """

  use PhoenixKitWeb, :html
  use Gettext, backend: PhoenixKitInbox.Gettext

  alias PhoenixKitInbox.Body
  alias PhoenixKitInbox.Errors
  alias PhoenixKitInbox.Schemas.Signature
  alias PhoenixKitInbox.Signatures

  @doc "Puts `mailbox`'s signatures and a blank form on the socket (`nil`: none)."
  @spec assign_editor(Phoenix.LiveView.Socket.t(), map() | nil) :: Phoenix.LiveView.Socket.t()
  def assign_editor(socket, mailbox) do
    socket
    |> assign(:sig_mailbox, mailbox)
    |> assign(:signatures, if(mailbox, do: Signatures.list(mailbox.uuid), else: []))
    |> assign(:sig_editing, nil)
    |> assign(:sig_form, nil)
  end

  @doc "Handles the editor's `\"sig_*\"` events."
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("sig_new", _params, socket) do
    {:noreply,
     socket
     |> assign(:sig_editing, :new)
     |> assign(:sig_form, form_for(%{"label" => "", "body" => "", "is_default" => "false"}))}
  end

  def handle_event("sig_edit", %{"uuid" => uuid}, socket) do
    case Enum.find(socket.assigns.signatures, &(&1.uuid == uuid)) do
      %Signature{} = signature ->
        {:noreply,
         socket
         |> assign(:sig_editing, signature.uuid)
         |> assign(
           :sig_form,
           form_for(%{
             "label" => signature.label,
             "body" => signature.body,
             "is_default" => to_string(signature.is_default)
           })
         )}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("sig_cancel", _params, socket) do
    {:noreply, assign(socket, sig_editing: nil, sig_form: nil)}
  end

  def handle_event("sig_save", %{"signature" => params}, socket) do
    scope = socket.assigns.scope

    result =
      case {socket.assigns.sig_editing, socket.assigns.sig_mailbox} do
        {:new, %{} = mailbox} ->
          Signatures.create_signature(scope, mailbox, params)

        {uuid, _} when is_binary(uuid) ->
          Signatures.update_signature(scope, %Signature{uuid: uuid}, params)

        _ ->
          {:error, :not_found}
      end

    case result do
      {:ok, _signature} ->
        {:noreply,
         socket
         |> assign_editor(socket.assigns.sig_mailbox)
         |> Phoenix.LiveView.put_flash(:info, gettext("Signature saved."))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:sig_form, form_for(params))
         |> Phoenix.LiveView.put_flash(:error, Errors.message(changeset))}

      {:error, reason} ->
        {:noreply, Phoenix.LiveView.put_flash(socket, :error, Errors.message(reason))}
    end
  end

  def handle_event("sig_delete", %{"uuid" => uuid}, socket) do
    case Signatures.delete_signature(socket.assigns.scope, %Signature{uuid: uuid}) do
      :ok ->
        {:noreply,
         socket
         |> assign_editor(socket.assigns.sig_mailbox)
         |> Phoenix.LiveView.put_flash(:info, gettext("Signature deleted."))}

      {:error, reason} ->
        {:noreply, Phoenix.LiveView.put_flash(socket, :error, Errors.message(reason))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp form_for(params), do: to_form(params, as: :signature)

  attr(:id, :string, required: true)
  attr(:signatures, :list, required: true)
  attr(:editing, :any, required: true)
  attr(:form, :any, required: true)

  @doc "The signature list with its add/edit form."
  def editor(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col gap-3">
      <p :if={@signatures == [] and is_nil(@editing)} class="text-sm text-base-content/60">
        {gettext("No signatures yet.")}
      </p>

      <div
        :for={signature <- @signatures}
        id={"signature-#{signature.uuid}"}
        class="rounded-box border border-base-300 p-3 flex flex-col gap-2"
      >
        <div class="flex items-center gap-2">
          <span class="font-medium">{signature.label}</span>
          <span :if={signature.is_default} class="badge badge-primary badge-sm">
            {gettext("Default")}
          </span>
          <div class="ml-auto flex gap-1">
            <button
              type="button"
              class="btn btn-ghost btn-xs"
              phx-click="sig_edit"
              phx-value-uuid={signature.uuid}
            >
              <.icon name="hero-pencil-square" class="w-4 h-4" /> {gettext("Edit")}
            </button>
            <button
              type="button"
              class="btn btn-ghost btn-xs text-error"
              phx-click="sig_delete"
              phx-value-uuid={signature.uuid}
              data-confirm={gettext("Delete this signature?")}
            >
              <.icon name="hero-trash" class="w-4 h-4" /> {gettext("Delete")}
            </button>
          </div>
        </div>
        <div class="prose prose-sm max-w-none text-base-content/80">
          {Body.markdown_html(signature.body)}
        </div>
      </div>

      <.form
        :if={@form}
        for={@form}
        id={"#{@id}-form"}
        phx-submit="sig_save"
        class="rounded-box border border-base-300 p-3 flex flex-col gap-2"
      >
        <.input field={@form[:label]} type="text" label={gettext("Name")} />
        <.textarea
          field={@form[:body]}
          label={gettext("Signature (Markdown)")}
          rows="5"
        />
        <.checkbox field={@form[:is_default]} label={gettext("Use by default")} />
        <div class="flex justify-end gap-2">
          <button type="button" class="btn btn-ghost btn-sm" phx-click="sig_cancel">
            {gettext("Cancel")}
          </button>
          <button type="submit" class="btn btn-primary btn-sm">{gettext("Save")}</button>
        </div>
      </.form>

      <div :if={is_nil(@form)}>
        <button type="button" class="btn btn-ghost btn-sm" phx-click="sig_new">
          <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add signature")}
        </button>
      </div>
    </div>
    """
  end
end
