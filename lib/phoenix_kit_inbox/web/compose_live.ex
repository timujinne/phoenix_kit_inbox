defmodule PhoenixKitInbox.Web.ComposeLive do
  @moduledoc """
  Compose, reply, forward, and save drafts.

  A separate LiveView rather than a modal inside `InboxLive`: composing has its
  own URL (`/admin/inbox/compose?reply_to=…`), which means a half-written reply
  survives a page reload and can be linked to from a notification.

  ## Draft handling

  The form autosaves on change (debounced) once there's anything worth saving,
  so `@draft_uuid` fills in after the first save and every later save updates
  the same message. Sending promotes that same row — the draft *becomes* the
  sent message rather than being copied and deleted, which keeps the uuid
  stable for anything already linking to it.

  ## Access

  Composing requires `"write"` on the sending mailbox — `"read"` grantees on a
  shared mailbox can follow the conversation but can't send as it. The check
  that counts is in `Messages.send_message/4`, called with the session scope.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitInbox.Errors
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Paths
  alias PhoenixKitInbox.Schemas.Message

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    user = socket.assigns[:phoenix_kit_current_user]

    socket =
      socket
      |> assign(:page_title, gettext_str("New message"))
      |> assign(:module_access, scope && Scope.has_module_access?(scope, "inbox"))
      |> assign(:scope, scope)
      |> assign(:current_user, user)
      |> assign(:mailboxes, sendable_mailboxes(user))
      |> assign(:mailbox, nil)
      |> assign(:draft_uuid, nil)
      |> assign(:parent_uuid, nil)
      |> assign(:saving, false)
      |> assign(:recipients, recipient_suggestions(user))
      |> assign(:form, to_form(blank_params()))

    {:ok, socket}
  end

  # Loaded once at mount, not per keystroke. The list is every addressable user
  # plus every shared mailbox, which is small enough to hand to the browser
  # whole — a <datalist> then filters client-side with no round trip. If an
  # installation ever grows past the cap, this becomes a phx-change lookup
  # against the same `Mailboxes.search_recipients/3`.
  defp recipient_suggestions(%{uuid: uuid}) when is_binary(uuid) do
    Mailboxes.search_recipients(uuid, "", limit: 200)
  rescue
    _ -> []
  end

  defp recipient_suggestions(_), do: []

  # Only mailboxes the user can actually send as show up in the From picker —
  # listing a read-only shared mailbox there would produce a send that fails
  # authorization after the user has written the whole message.
  defp sendable_mailboxes(%{uuid: uuid}) when is_binary(uuid) do
    uuid
    |> Mailboxes.list_accessible_mailboxes()
    |> Enum.filter(&(Mailboxes.access_level(&1, uuid) in ~w(write admin)))
  end

  defp sendable_mailboxes(_), do: []

  @impl true
  def handle_params(params, _uri, socket) do
    if socket.assigns.module_access do
      {:noreply, socket |> assign_mailbox(params["mailbox"]) |> prefill(params)}
    else
      {:noreply, socket}
    end
  end

  defp assign_mailbox(socket, uuid) do
    mailbox =
      Enum.find(
        socket.assigns.mailboxes,
        List.first(socket.assigns.mailboxes),
        &(&1.uuid == uuid)
      )

    assign(socket, :mailbox, mailbox)
  end

  # Three entry points share one form: a blank compose, a reply (recipient and
  # thread inherited from the parent), and a forward (body quoted, no
  # recipient). Resuming a draft reloads whatever was saved.
  defp prefill(socket, %{"reply_to" => uuid}) when is_binary(uuid),
    do: prefill_reply(socket, uuid)

  defp prefill(socket, %{"forward" => uuid}) when is_binary(uuid),
    do: prefill_forward(socket, uuid)

  defp prefill(socket, %{"draft" => uuid}) when is_binary(uuid), do: prefill_draft(socket, uuid)
  defp prefill(socket, _params), do: socket

  defp prefill_reply(%{assigns: %{mailbox: nil}} = socket, _uuid), do: socket

  defp prefill_reply(socket, uuid) do
    case Messages.fetch_for_mailbox(socket.assigns.mailbox.uuid, uuid) do
      {:ok, %{message: message}} ->
        sender = sender_mailbox_handle(message)

        socket
        |> assign(:parent_uuid, message.uuid)
        |> assign(:page_title, gettext_str("Reply"))
        |> assign(
          :form,
          to_form(%{
            "to" => sender,
            "cc" => "",
            "bcc" => "",
            "subject" => prefixed_subject("Re: ", message.subject),
            "body" => quote_body(message)
          })
        )

      {:error, reason} ->
        put_flash(socket, :error, Errors.message(reason))
    end
  end

  defp prefill_forward(%{assigns: %{mailbox: nil}} = socket, _uuid), do: socket

  defp prefill_forward(socket, uuid) do
    case Messages.fetch_for_mailbox(socket.assigns.mailbox.uuid, uuid) do
      {:ok, %{message: message}} ->
        socket
        |> assign(:page_title, gettext_str("Forward"))
        |> assign(
          :form,
          to_form(%{
            "to" => "",
            "cc" => "",
            "bcc" => "",
            "subject" => prefixed_subject("Fwd: ", message.subject),
            "body" => quote_body(message)
          })
        )

      {:error, reason} ->
        put_flash(socket, :error, Errors.message(reason))
    end
  end

  defp prefill_draft(%{assigns: %{mailbox: nil}} = socket, _uuid), do: socket

  defp prefill_draft(socket, uuid) do
    case Messages.fetch_for_mailbox(socket.assigns.mailbox.uuid, uuid) do
      {:ok, %{message: %Message{status: "draft"} = message}} ->
        recipients = Messages.draft_recipients(message)

        socket
        |> assign(:draft_uuid, message.uuid)
        |> assign(:parent_uuid, message.parent_uuid)
        |> assign(:page_title, gettext_str("Draft"))
        |> assign(
          :form,
          to_form(%{
            "to" => recipients["to"],
            "cc" => recipients["cc"],
            "bcc" => recipients["bcc"],
            "subject" => message.subject || "",
            "body" => message.body || ""
          })
        )

      _ ->
        socket
    end
  end

  # ── Events ──────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("validate", params, socket) do
    {:noreply, assign(socket, :form, to_form(strip_meta(params)))}
  end

  # The Save draft button is a phx-click, which carries no form fields — the
  # draft is whatever the form holds, as kept current by "validate".
  def handle_event("save_draft", params, socket) do
    {:noreply, save_draft(socket, Map.merge(socket.assigns.form.params, strip_meta(params)))}
  end

  def handle_event("send", params, socket) do
    params = strip_meta(params)

    # Authorization (inbox permission, write on the mailbox) is checked by
    # send_message/4 itself; the From picker only hides what would fail.
    with %{} = mailbox <- socket.assigns.mailbox,
         attrs <- send_attrs(socket, params),
         {:ok, _message} <- Messages.send_message(socket.assigns.scope, mailbox, attrs) do
      {:noreply,
       socket
       |> put_flash(:info, gettext_str("Message sent."))
       |> push_navigate(to: Paths.inbox(mailbox: mailbox.uuid, folder: "sent"))}
    else
      nil ->
        {:noreply, put_flash(socket, :error, Errors.message(:mailbox_not_found))}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:form, to_form(params))
         |> put_flash(:error, Errors.message(reason))}
    end
  end

  def handle_event("discard", _params, socket) do
    case {socket.assigns.mailbox, socket.assigns.draft_uuid} do
      {%{} = mailbox, uuid} when is_binary(uuid) ->
        case Messages.delete_draft(socket.assigns.scope, mailbox, uuid) do
          :ok ->
            {:noreply,
             socket
             |> put_flash(:info, gettext_str("Draft discarded."))
             |> push_navigate(to: back_path(socket))}

          # The draft stays, so the page does too: leaving would look like
          # it had been discarded.
          {:error, reason} ->
            {:noreply, put_flash(socket, :error, Errors.message(reason))}
        end

      _ ->
        {:noreply, push_navigate(socket, to: back_path(socket))}
    end
  end

  def handle_event("select_mailbox", %{"mailbox" => uuid}, socket) do
    {:noreply, assign_mailbox(socket, uuid)}
  end

  defp save_draft(%{assigns: %{mailbox: nil}} = socket, _params), do: socket

  defp save_draft(socket, params) do
    mailbox = socket.assigns.mailbox

    attrs =
      params
      |> Map.take(~w(to cc bcc subject body))
      |> Map.put("uuid", socket.assigns.draft_uuid)
      |> Map.put("parent_uuid", socket.assigns.parent_uuid)

    case Messages.save_draft(socket.assigns.scope, mailbox, attrs) do
      {:ok, message} ->
        socket
        |> assign(:draft_uuid, message.uuid)
        |> assign(:form, to_form(params))
        |> put_flash(:info, gettext_str("Draft saved."))

      {:error, reason} ->
        put_flash(socket, :error, Errors.message(reason))
    end
  end

  defp send_attrs(socket, params) do
    params
    |> Map.take(~w(to cc bcc subject body))
    |> Map.put("uuid", socket.assigns.draft_uuid)
    |> Map.put("parent_uuid", socket.assigns.parent_uuid)
  end

  # Phoenix injects "_target"/"_csrf_token" into form payloads; they'd end up in
  # the form assign and re-render as stray values.
  defp strip_meta(params), do: Map.drop(params, ~w(_target _csrf_token))

  defp back_path(%{assigns: %{mailbox: %{uuid: uuid}}}), do: Paths.inbox(mailbox: uuid)
  defp back_path(_socket), do: Paths.inbox()

  # ── Render ──────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col px-4 py-6 gap-4">
      <div :if={not @module_access} class="alert alert-warning">
        <.icon name="hero-lock-closed" class="w-5 h-5" />
        <span>{gettext_str("You don't have permission to use Inbox.")}</span>
      </div>

      <div :if={@module_access and @mailboxes == []} class="alert alert-info">
        <.icon name="hero-information-circle" class="w-5 h-5" />
        <span>{gettext_str("You don't have any mailbox you can send from.")}</span>
      </div>

      <.compose_form
        :if={@module_access and @mailbox}
        form={@form}
        mailbox={@mailbox}
        mailboxes={@mailboxes}
        recipients={@recipients}
        draft_uuid={@draft_uuid}
        back={back_path(assigns)}
      />
    </div>
    """
  end

  attr(:form, :any, required: true)
  attr(:mailbox, :any, required: true)
  attr(:mailboxes, :list, required: true)
  attr(:recipients, :list, required: true)
  attr(:draft_uuid, :any, required: true)
  attr(:back, :string, required: true)

  defp compose_form(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow max-w-4xl">
      <div class="card-body gap-4">
        <.form for={@form} phx-change="validate" phx-submit="send" class="flex flex-col gap-3">
          <div :if={length(@mailboxes) > 1} class="flex items-center gap-2">
            <span class="text-sm w-16 shrink-0">{gettext_str("From")}</span>
            <.select
              name="mailbox"
              value={@mailbox.uuid}
              options={Enum.map(@mailboxes, &{&1.name, &1.uuid})}
              class="select-sm"
              phx-change="select_mailbox"
            />
          </div>

          <.input
            field={@form[:to]}
            type="text"
            label={gettext_str("To")}
            placeholder={gettext_str("@username, email or shared mailbox — comma separated")}
            list="phoenix-kit-inbox-recipients"
          />
          <.input
            field={@form[:cc]}
            type="text"
            label={gettext_str("Cc")}
            list="phoenix-kit-inbox-recipients"
          />
          <.input
            field={@form[:bcc]}
            type="text"
            label={gettext_str("Bcc")}
            list="phoenix-kit-inbox-recipients"
          />

          <%!-- A plain <datalist> rather than a JS-driven picker: no hook to
                register, works when the page is reached via navigate/2, and the
                browser handles filtering. One list serves all three fields. --%>
          <datalist id="phoenix-kit-inbox-recipients">
            <option :for={recipient <- @recipients} value={recipient.handle}>
              {recipient.label}
            </option>
          </datalist>
          <.input field={@form[:subject]} type="text" label={gettext_str("Subject")} />
          <.textarea field={@form[:body]} label={gettext_str("Message")} rows="14" />

          <div class="card-actions justify-end flex-wrap gap-2 pt-2">
            <.link navigate={@back} class="btn btn-ghost btn-sm">
              {gettext_str("Cancel")}
            </.link>

            <button
              :if={@draft_uuid}
              type="button"
              class="btn btn-ghost btn-sm text-error"
              phx-click="discard"
              data-confirm={gettext_str("Discard this draft?")}
            >
              <.icon name="hero-trash" class="w-4 h-4" />
              {gettext_str("Discard draft")}
            </button>

            <button type="button" class="btn btn-ghost btn-sm" phx-click="save_draft">
              <.icon name="hero-document" class="w-4 h-4" />
              {gettext_str("Save draft")}
            </button>

            <button type="submit" class="btn btn-primary btn-sm">
              <.icon name="hero-paper-airplane" class="w-4 h-4" />
              {gettext_str("Send")}
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp blank_params do
    %{"to" => "", "cc" => "", "bcc" => "", "subject" => "", "body" => ""}
  end

  defp sender_mailbox_handle(%Message{sender_mailbox_uuid: uuid}) do
    case Mailboxes.fetch_mailbox(uuid) do
      {:ok, mailbox} -> Mailboxes.recipient_handle(mailbox) || ""
      _ -> ""
    end
  end

  defp prefixed_subject(prefix, nil), do: String.trim_trailing(prefix)

  defp prefixed_subject(prefix, subject) do
    if String.starts_with?(subject, prefix), do: subject, else: prefix <> subject
  end

  defp quote_body(%Message{body: nil}), do: "\n\n"

  defp quote_body(%Message{body: body}) do
    quoted = body |> String.split("\n") |> Enum.map_join("\n", &("> " <> &1))
    "\n\n" <> quoted
  end

  defp gettext_str(msgid), do: Gettext.gettext(PhoenixKitWeb.Gettext, msgid)
end
