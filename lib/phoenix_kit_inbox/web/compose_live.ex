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

  ## Attachments

  Files come from two places. An upload (`allow_upload/3`) stays in the
  LiveView's temporary upload until the draft is saved or the message sent,
  and goes to `Messages` then as `attachments_data:` — nothing reaches
  Storage before that, so an abandoned compose leaves nothing behind and
  taking an upload off just cancels it. "Attach existing file" is core's
  media picker, which lists every file on purpose, so each pick is checked
  with `Attachments.describe/2` and a file the user may not read is refused
  by name (a file uploaded inside the picker lands in Media first, as the
  picker does everywhere, and is snapshotted at send). A forward and a
  reopened draft start with the attachments they carry. The checks that
  count are in `Messages.send_message/4`.

  ## Signature and Reply-To

  The sending mailbox's default signature is put at the end of a new
  message, a reply or a forward (`Signatures.block/1`); choosing another
  one, or another mailbox, swaps it while the block is as it was put there
  and leaves it alone once the writer edited it (`Signatures.swap_block/3`).
  A reopened draft keeps its body as saved. Only the signatures of the
  sending mailbox can be chosen.

  The Reply-To picker offers `Identities.reply_to_options/2` — the user's
  email and the shared addresses they write to — with the mailbox's default
  chosen; the send checks the choice again. A reply is addressed to the
  message's Reply-To when it has one.

  ## Sender and external recipients

  The "Send as" picker offers the sending identities the user may use from
  the chosen mailbox (`Identities.list_usable/2`), plus "inside the
  application only" — while external sending is open
  (`PhoenixKitInbox.Outbound.open?/0`). An email address that is
  no member's or shared mailbox's goes to that address outside the
  application — it needs a chosen identity, and the send checks the rest
  (`Messages.send_message/4`). The external part goes after the send, so
  the page does not wait for it; the reading pane shows how it went.

  ## Access

  Composing requires `"write"` on the sending mailbox — `"read"` grantees on a
  shared mailbox can follow the conversation but can't send as it. The check
  that counts is in `Messages.send_message/4`, called with the session scope.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitInbox.Gettext

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Format
  alias PhoenixKitInbox.Attachments
  alias PhoenixKitInbox.Errors
  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Outbound
  alias PhoenixKitInbox.Paths
  alias PhoenixKitInbox.Schemas.Message
  alias PhoenixKitInbox.Signatures

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    user = socket.assigns[:phoenix_kit_current_user]

    socket =
      socket
      |> assign(:page_title, gettext("New message"))
      |> assign(:module_access, Scope.can?(scope, "inbox"))
      |> assign(:scope, scope)
      |> assign(:current_user, user)
      |> assign(:mailboxes, [])
      |> assign(:mailbox, nil)
      |> assign(:draft_uuid, nil)
      |> assign(:parent_uuid, nil)
      |> assign(:saving, false)
      |> assign(:recipients, [])
      |> assign(:form, to_form(blank_params()))
      |> assign(:attachments, [])
      |> assign(:signatures, [])
      |> assign(:signature_uuid, "")
      |> assign(:signature_block, "")
      |> assign(:reply_to_options, [])
      |> assign(:identities, [])
      |> assign(:show_media_selector, false)
      |> allow_upload(:attachments,
        accept: :any,
        max_entries: Attachments.max_files(),
        max_file_size: Attachments.max_upload_bytes(),
        auto_upload: true
      )

    {:ok, socket}
  end

  # Loaded on navigation and mailbox changes, not per keystroke. The list is
  # addressable users and shared mailboxes, handed to the browser whole — a
  # <datalist> filters client-side with no round trip. If an
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
    access = Scope.can?(socket.assigns.scope, "inbox")
    socket = assign(socket, :module_access, access)

    if access do
      {:noreply,
       socket
       |> ensure_personal_mailbox()
       |> assign_mailbox(params["mailbox"])
       |> prefill(params)
       |> init_sender(Map.has_key?(params, "draft"))}
    else
      {:noreply, socket}
    end
  end

  # Compose may be a user's first Inbox page. Without this their personal
  # mailbox doesn't exist yet and only shared mailboxes would be offered.
  defp ensure_personal_mailbox(%{assigns: %{current_user: user}} = socket) when is_map(user) do
    case Mailboxes.ensure_user_mailbox(user) do
      {:ok, _personal} ->
        socket

      {:error, reason} ->
        Logger.warning("[Inbox] could not resolve personal mailbox: #{inspect(reason)}")
        put_flash(socket, :error, Errors.message(reason))
    end
  end

  defp ensure_personal_mailbox(socket), do: socket

  defp assign_mailbox(socket, uuid) do
    # The socket can outlive a grant. Re-read before loading messages or
    # signatures, including when the From picker changes without a patch.
    mailboxes =
      if Scope.can?(socket.assigns.scope, "inbox"),
        do: sendable_mailboxes(socket.assigns.current_user),
        else: []

    mailbox =
      Enum.find(
        mailboxes,
        List.first(mailboxes),
        &(&1.uuid == uuid)
      )

    socket
    |> assign(:mailboxes, mailboxes)
    |> assign(
      :recipients,
      if(mailbox, do: recipient_suggestions(socket.assigns.current_user), else: [])
    )
    |> assign(:mailbox, mailbox)
    |> assign(:signatures, mailbox_signatures(mailbox))
    |> assign(:reply_to_options, reply_to_options(socket.assigns.scope, mailbox))
    |> assign(:identities, usable_identities(socket.assigns.scope, mailbox))
  end

  # The identities that fit the mailbox: one bound to it, or — from the
  # user's own personal mailbox — the personal and common ones. None while
  # external sending is closed: there would be nothing to send as.
  defp usable_identities(_scope, nil), do: []

  defp usable_identities(scope, mailbox) do
    if Outbound.open?(), do: Identities.list_usable(scope, mailbox), else: []
  end

  defp mailbox_signatures(nil), do: []
  defp mailbox_signatures(mailbox), do: Signatures.list(mailbox.uuid)

  defp reply_to_options(_scope, nil), do: []
  defp reply_to_options(scope, mailbox), do: Identities.reply_to_options(scope, mailbox)

  # After the prefill: a new message, reply or forward gets the mailbox's
  # default signature; a reopened draft keeps its body and its Reply-To.
  defp init_sender(%{assigns: %{mailbox: nil}} = socket, _draft?), do: socket

  defp init_sender(socket, true) do
    saved =
      case socket.assigns.form.params["reply_to"] do
        address when is_binary(address) and address != "" -> address
        _ -> default_reply_to(socket)
      end

    put_form_params(socket, %{"reply_to" => saved})
  end

  defp init_sender(socket, false) do
    socket
    |> put_form_params(%{"reply_to" => default_reply_to(socket)})
    |> switch_signature(default_signature(socket), socket.assigns.form.params["body"] || "")
  end

  defp default_signature(socket), do: Enum.find(socket.assigns.signatures, & &1.is_default)

  defp default_reply_to(socket),
    do: Identities.default_reply_to(socket.assigns.reply_to_options) || ""

  # Swaps the signature block at the end of `body`; an edited block is kept.
  defp switch_signature(socket, signature, body) do
    case Signatures.swap_block(body, socket.assigns.signature_block, signature) do
      {:ok, new_body} ->
        socket
        |> assign(:signature_uuid, (signature && signature.uuid) || "")
        |> assign(:signature_block, Signatures.block(signature))
        |> put_form_params(%{"body" => new_body})

      :edited ->
        socket
        |> put_form_params(%{"body" => body})
        |> put_flash(
          :warning,
          gettext("The signature in the message was edited, so it was left as it is.")
        )
    end
  end

  # A chosen identity that does not fit the new mailbox is let go.
  defp keep_identity(socket) do
    chosen = socket.assigns.form.params["identity_uuid"]

    if Enum.any?(socket.assigns.identities, &(&1.identity_uuid == chosen)),
      do: socket,
      else: put_form_params(socket, %{"identity_uuid" => ""})
  end

  defp sent_flash(%Message{external_status: :pending}),
    do: gettext("Message sent. The email to external addresses is on its way.")

  defp sent_flash(_message), do: gettext("Message sent.")

  defp put_form_params(socket, params) do
    assign(socket, :form, to_form(Map.merge(socket.assigns.form.params, params)))
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
        sender = reply_address(message)

        socket
        |> assign(:parent_uuid, message.uuid)
        |> assign(:page_title, gettext("Reply"))
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
        |> assign(:page_title, gettext("Forward"))
        |> assign(:attachments, chips_for(message.uuid))
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
        sender = Messages.draft_sender(message)

        socket
        |> assign(:draft_uuid, message.uuid)
        |> assign(:parent_uuid, message.parent_uuid)
        |> assign(:page_title, gettext("Draft"))
        |> assign(:attachments, chips_for(message.uuid))
        |> assign(
          :form,
          to_form(%{
            "to" => recipients["to"],
            "cc" => recipients["cc"],
            "bcc" => recipients["bcc"],
            "subject" => message.subject || "",
            "body" => message.body || "",
            "reply_to" => sender["reply_to"],
            "identity_uuid" => sender["identity_uuid"]
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
         {:ok, uploads} <- pending_uploads(socket),
         {:ok, message} <-
           Messages.send_message(socket.assigns.scope, mailbox, attrs, attachments_data: uploads) do
      {:noreply,
       socket
       |> put_flash(:info, sent_flash(message))
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
             |> put_flash(:info, gettext("Draft discarded."))
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

  def handle_event("select_mailbox", %{"mailbox" => uuid} = params, socket) do
    body = form_body(socket, params)
    previous_uuid = socket.assigns.mailbox && socket.assigns.mailbox.uuid

    socket =
      socket
      |> put_form_params(strip_meta(params))
      |> assign_mailbox(uuid)

    # A saved draft belongs to its original mailbox. Switching starts a
    # new draft there; the original remains available in its Drafts folder.
    socket =
      if socket.assigns.mailbox && socket.assigns.mailbox.uuid == previous_uuid,
        do: socket,
        else: assign(socket, :draft_uuid, nil)

    {:noreply,
     socket
     |> put_form_params(%{"reply_to" => default_reply_to(socket)})
     |> keep_identity()
     |> switch_signature(default_signature(socket), body)}
  end

  # Only the sending mailbox's signatures can be chosen: a uuid that is not
  # one of them (forged, or another mailbox's) means "no signature".
  def handle_event("select_signature", params, socket) do
    signature = Enum.find(socket.assigns.signatures, &(&1.uuid == params["signature"]))

    {:noreply,
     socket
     |> put_form_params(Map.drop(strip_meta(params), ["signature"]))
     |> switch_signature(signature, form_body(socket, params))}
  end

  def handle_event("open_media_selector", _params, socket) do
    {:noreply, assign(socket, :show_media_selector, true)}
  end

  # Taking a chip off only changes what the next save or send names; a
  # draft's snapshot no other message names is deleted by that save.
  def handle_event("remove_attachment", %{"file" => file_uuid}, socket) do
    {:noreply,
     assign(
       socket,
       :attachments,
       Enum.reject(socket.assigns.attachments, &(&1.file_uuid == file_uuid))
     )}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachments, ref)}
  end

  @impl true
  def handle_info({:media_selected, file_uuids}, socket) do
    {chips, refused} =
      Enum.reduce(List.wrap(file_uuids), {[], []}, fn uuid, {chips, refused} ->
        case Attachments.describe(socket.assigns.scope, uuid) do
          {:ok, chip} ->
            {[chip | chips], refused}

          {:error, reason} ->
            {chips, [{file_label(socket.assigns.scope, uuid), reason} | refused]}
        end
      end)

    socket =
      chips
      |> Enum.reverse()
      |> Enum.reduce(assign(socket, :show_media_selector, false), &add_attachment(&2, &1))

    {:noreply, refuse_picks(socket, Enum.reverse(refused))}
  end

  def handle_info({:media_selector_closed}, socket) do
    {:noreply, assign(socket, :show_media_selector, false)}
  end

  # Picker choices that could not be attached, named when the user may read
  # them (`file_label/2`), so they learn which did not make it and why.
  defp refuse_picks(socket, []), do: socket

  defp refuse_picks(socket, [{_name, reason} | _] = refused) do
    names = Enum.map_join(refused, ", ", fn {name, _} -> name end)

    put_flash(
      socket,
      :error,
      gettext("Not attached: %{names}. %{reason}",
        names: names,
        reason: Errors.message(reason)
      )
    )
  end

  # A refused pick's name, only for a file the user may read: the uuid comes
  # from the client, so another user's file name must not come back in a flash.
  defp file_label(scope, uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(uuid),
         %{} = file <- Storage.get_file(uuid),
         true <- Libraries.can?(scope, file, :read) do
      file.original_file_name || file.file_name
    else
      _ -> gettext("a file")
    end
  end

  # The picker lists the user's own Media files; a system role (Owner, Admin),
  # who may read every file, gets the whole library. Core's `MediaSelectorModal`
  # without `user_uuid` lists every user's files, names and thumbnails included.
  defp media_selector(scope) do
    if Scope.system_role?(scope),
      do: PhoenixKitWeb.Live.Components.MediaSelectorModal,
      else: PhoenixKitWeb.Live.Components.UserMediaSelectorModal
  end

  # The finished uploads as `attachments_data:` entries. `:postpone` keeps
  # each entry and its temporary file: a refused send keeps the uploads for
  # the next try. The files are gone with the LiveView after a send.
  defp pending_uploads(socket) do
    case uploaded_entries(socket, :attachments) do
      {_done, [_ | _]} ->
        {:error, :uploads_in_progress}

      {[], []} ->
        {:ok, []}

      _ ->
        {:ok,
         consume_uploaded_entries(socket, :attachments, fn %{path: path}, entry ->
           {:postpone,
            %{path: path, filename: entry.client_name, content_type: entry.client_type}}
         end)}
    end
  end

  # After a draft save the uploads are the draft's snapshots: drop them here.
  defp clear_uploads(socket) do
    consume_uploaded_entries(socket, :attachments, fn _meta, _entry -> {:ok, nil} end)
    socket
  end

  defp add_attachment(socket, %{file_uuid: uuid} = chip) do
    attachments = socket.assigns.attachments

    cond do
      Enum.any?(attachments, &(&1.file_uuid == uuid)) ->
        socket

      length(attachments) >= Attachments.max_files() ->
        put_flash(
          socket,
          :error,
          Errors.message({:too_many_attachments, Attachments.max_files()})
        )

      true ->
        assign(socket, :attachments, attachments ++ [chip])
    end
  end

  defp chips_for(message_uuid) do
    message_uuid
    |> Attachments.list_for_message()
    |> Enum.map(fn row ->
      %{file_uuid: to_string(row.file_uuid), filename: row.filename, size_bytes: row.size_bytes}
    end)
  end

  defp attachment_attrs(socket),
    do: Enum.map(socket.assigns.attachments, &%{"file_uuid" => &1.file_uuid})

  defp save_draft(%{assigns: %{mailbox: nil}} = socket, _params), do: socket

  defp save_draft(socket, params) do
    mailbox = socket.assigns.mailbox

    attrs =
      params
      |> Map.take(~w(to cc bcc subject body reply_to identity_uuid))
      |> Map.put("body_format", "markdown")
      |> Map.put("uuid", socket.assigns.draft_uuid)
      |> Map.put("parent_uuid", socket.assigns.parent_uuid)
      |> Map.put("attachments", attachment_attrs(socket))

    with {:ok, uploads} <- pending_uploads(socket),
         {:ok, message} <-
           Messages.save_draft(socket.assigns.scope, mailbox, attrs, attachments_data: uploads) do
      # The chips now name the draft's own snapshots (uploads included), so
      # the next save keeps them instead of copying anything again.
      socket
      |> clear_uploads()
      |> assign(:draft_uuid, message.uuid)
      |> assign(:attachments, chips_for(message.uuid))
      |> assign(:form, to_form(params))
      |> put_flash(:info, gettext("Draft saved."))
    else
      {:error, reason} -> put_flash(socket, :error, Errors.message(reason))
    end
  end

  defp send_attrs(socket, params) do
    params
    |> Map.take(~w(to cc bcc subject body reply_to identity_uuid))
    |> Map.put("body_format", "markdown")
    |> Map.put("uuid", socket.assigns.draft_uuid)
    |> Map.put("parent_uuid", socket.assigns.parent_uuid)
    |> Map.put("attachments", attachment_attrs(socket))
  end

  defp form_body(socket, params), do: params["body"] || socket.assigns.form.params["body"] || ""

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
        <span>{gettext("You don't have permission to use Inbox.")}</span>
      </div>

      <div :if={@module_access and @mailboxes == []} class="alert alert-info">
        <.icon name="hero-information-circle" class="w-5 h-5" />
        <span>{gettext("You don't have any mailbox you can send from.")}</span>
      </div>

      <.compose_form
        :if={@module_access and @mailbox}
        form={@form}
        mailbox={@mailbox}
        mailboxes={@mailboxes}
        recipients={@recipients}
        draft_uuid={@draft_uuid}
        back={back_path(assigns)}
        attachments={@attachments}
        uploads={@uploads}
        signatures={@signatures}
        signature_uuid={@signature_uuid}
        reply_to_options={@reply_to_options}
        identities={@identities}
      />

      <%!-- Mounted only while open: the picker reports back by message
            ({:media_selected, uuids} / {:media_selector_closed}). --%>
      <.live_component
        :if={@module_access and @show_media_selector}
        module={media_selector(@scope)}
        id="inbox-media-selector"
        show={true}
        mode={:multiple}
        selected_uuids={[]}
        title={gettext("Attach existing files")}
        phoenix_kit_current_user={@current_user}
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
  attr(:attachments, :list, required: true)
  attr(:uploads, :map, required: true)
  attr(:signatures, :list, required: true)
  attr(:signature_uuid, :string, required: true)
  attr(:reply_to_options, :list, required: true)
  attr(:identities, :list, required: true)

  defp compose_form(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow max-w-4xl">
      <div class="card-body gap-4">
        <.form
          for={@form}
          id="compose-form"
          phx-change="validate"
          phx-submit="send"
          class="flex flex-col gap-3"
        >
          <div :if={length(@mailboxes) > 1} class="flex items-center gap-2">
            <span class="text-sm min-w-24 shrink-0 whitespace-nowrap">{gettext("From")}</span>
            <.select
              name="mailbox"
              value={@mailbox.uuid}
              options={Enum.map(@mailboxes, &{&1.name, &1.uuid})}
              class="select-sm"
              phx-change="select_mailbox"
            />
          </div>

          <div :if={@identities != []} class="flex items-center gap-2">
            <span class="text-sm min-w-24 shrink-0 whitespace-nowrap">{gettext("Send as")}</span>
            <.select
              id="compose-identity"
              name="identity_uuid"
              value={@form.params["identity_uuid"] || ""}
              options={identity_choices(@identities)}
              class="select-sm"
            />
          </div>

          <.input
            field={@form[:to]}
            type="text"
            label={gettext("To")}
            placeholder={gettext("@username, email or shared mailbox — comma separated")}
            list="phoenix-kit-inbox-recipients"
          />
          <.input
            field={@form[:cc]}
            type="text"
            label={gettext("Cc")}
            list="phoenix-kit-inbox-recipients"
          />
          <.input
            field={@form[:bcc]}
            type="text"
            label={gettext("Bcc")}
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
          <div :if={length(@reply_to_options) > 1} class="flex items-center gap-2">
            <span class="text-sm min-w-24 shrink-0 whitespace-nowrap">{gettext("Reply-To")}</span>
            <.select
              id="compose-reply-to"
              name="reply_to"
              value={@form.params["reply_to"]}
              options={reply_to_choices(@reply_to_options)}
              class="select-sm"
            />
          </div>
          <input
            :if={length(@reply_to_options) <= 1}
            type="hidden"
            name="reply_to"
            value={@form.params["reply_to"] || ""}
          />

          <.input field={@form[:subject]} type="text" label={gettext("Subject")} />
          <.textarea field={@form[:body]} label={gettext("Message")} rows="14" />
          <p class="text-xs text-base-content/60 -mt-2">
            {gettext("Markdown: **bold**, _italic_, [link](https://…), - lists.")}
          </p>

          <div :if={@signatures != []} class="flex items-center gap-2">
            <span class="text-sm min-w-24 shrink-0 whitespace-nowrap">{gettext("Signature")}</span>
            <.select
              id="compose-signature"
              name="signature"
              value={@signature_uuid}
              options={[{gettext("No signature"), ""} | Enum.map(@signatures, &{&1.label, &1.uuid})]}
              class="select-sm"
              phx-change="select_signature"
            />
          </div>

          <.attachment_picker attachments={@attachments} upload={@uploads.attachments} />

          <div class="card-actions justify-end flex-wrap gap-2 pt-2">
            <.link navigate={@back} class="btn btn-ghost btn-sm">
              {gettext("Cancel")}
            </.link>

            <button
              :if={@draft_uuid}
              type="button"
              class="btn btn-ghost btn-sm text-error"
              phx-click="discard"
              data-confirm={gettext("Discard this draft?")}
            >
              <.icon name="hero-trash" class="w-4 h-4" />
              {gettext("Discard draft")}
            </button>

            <button type="button" class="btn btn-ghost btn-sm" phx-click="save_draft">
              <.icon name="hero-document" class="w-4 h-4" />
              {gettext("Save draft")}
            </button>

            <button type="submit" class="btn btn-primary btn-sm">
              <.icon name="hero-paper-airplane" class="w-4 h-4" />
              {gettext("Send")}
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  attr(:attachments, :list, required: true)
  attr(:upload, :any, required: true)

  defp attachment_picker(assigns) do
    ~H"""
    <div id="compose-attachments" class="flex flex-col gap-2">
      <div
        :if={@attachments != [] or @upload.entries != []}
        class="flex flex-wrap gap-2"
      >
        <span
          :for={attachment <- @attachments}
          id={"attachment-#{attachment.file_uuid}"}
          class="badge badge-outline badge-lg gap-2 max-w-full"
        >
          <.icon name="hero-paper-clip" class="w-4 h-4 shrink-0" />
          <span class="truncate">{attachment.filename}</span>
          <span class="text-xs opacity-60 shrink-0">{Format.bytes(attachment.size_bytes)}</span>
          <button
            type="button"
            class="btn btn-ghost btn-xs btn-circle"
            phx-click="remove_attachment"
            phx-value-file={attachment.file_uuid}
            aria-label={gettext("Remove attachment")}
            title={gettext("Remove attachment")}
          >
            <.icon name="hero-x-mark" class="w-3 h-3" />
          </button>
        </span>

        <span
          :for={entry <- @upload.entries}
          id={"upload-#{entry.ref}"}
          class={[
            "badge badge-ghost badge-lg gap-2 max-w-full",
            entry.valid? == false && "badge-error"
          ]}
        >
          <.icon name="hero-arrow-up-tray" class="w-4 h-4 shrink-0" />
          <span class="truncate">{entry.client_name}</span>
          <span :if={entry.valid?} class="text-xs opacity-60 shrink-0">{entry.progress}%</span>
          <span :for={error <- upload_errors(@upload, entry)} class="text-xs shrink-0">
            {upload_error_text(error)}
          </span>
          <button
            type="button"
            class="btn btn-ghost btn-xs btn-circle"
            phx-click="cancel_upload"
            phx-value-ref={entry.ref}
            aria-label={gettext("Cancel upload")}
          >
            <.icon name="hero-x-mark" class="w-3 h-3" />
          </button>
        </span>
      </div>

      <div class="flex flex-wrap items-center gap-2">
        <label class="btn btn-ghost btn-sm">
          <.icon name="hero-arrow-up-tray" class="w-4 h-4" />
          {gettext("Upload files")}
          <.live_file_input upload={@upload} class="hidden" />
        </label>

        <button
          type="button"
          id="attach-existing"
          class="btn btn-ghost btn-sm"
          phx-click="open_media_selector"
        >
          <.icon name="hero-paper-clip" class="w-4 h-4" />
          {gettext("Attach existing file")}
        </button>
      </div>

      <p :for={error <- upload_errors(@upload)} class="text-sm text-error">
        {upload_error_text(error)}
      </p>
    </div>
    """
  end

  # Without a default (a shared mailbox with no address) the first choice is
  # "none": replies then go to the sending mailbox.
  defp reply_to_choices(options) do
    choices = Enum.map(options, &{&1.label, &1.address})

    if Identities.default_reply_to(options),
      do: choices,
      else: [{gettext("No Reply-To — replies go to this mailbox"), ""} | choices]
  end

  # "Inside only" first: an external send is a choice, never the default.
  defp identity_choices(identities) do
    [
      {gettext("Inside the application only"), ""}
      | Enum.map(identities, &{"#{&1.label} <#{&1.from_address}>", &1.identity_uuid})
    ]
  end

  defp upload_error_text(:too_large), do: gettext("Larger than the upload limit.")
  defp upload_error_text(:too_many_files), do: gettext("Too many files.")
  defp upload_error_text(:not_accepted), do: gettext("This file type is not accepted.")
  defp upload_error_text(_), do: gettext("The upload failed.")

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp blank_params do
    %{"to" => "", "cc" => "", "bcc" => "", "subject" => "", "body" => ""}
  end

  # The message's Reply-To when it has one (the send checked it), else its
  # sending mailbox.
  defp reply_address(%Message{metadata: %{"reply_to" => address}})
       when is_binary(address) and address != "",
       do: address

  defp reply_address(message), do: sender_mailbox_handle(message)

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
end
