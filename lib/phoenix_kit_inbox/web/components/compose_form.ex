defmodule PhoenixKitInbox.Web.Components.ComposeForm do
  @moduledoc """
  A compose form a host page embeds: who it is from, to whom, the subject, the
  text, the files — and little else. Cc, Bcc and the signature wait behind
  small buttons; a block the host's draft filled opens on its own.

      <.live_component
        module={PhoenixKitInbox.Web.Components.ComposeForm}
        id="order-letter"
        scope={@scope}
        draft={@draft}
        around_send={&MyHost.around_send/3}
        authorize_attachments={&MyHost.authorize_attachments/3}
        recipient_sources={[MyHost.ClientSource]}
      />

  The form is a thin view over `PhoenixKitInbox.Web.Components.ComposePipeline`
  and trusts nothing the browser says. The draft (`ComposeDraft`) lives in the
  component's assigns; the recipients are server-side structures; the sender is
  chosen from a list the server made, and a choice the browser sends is looked
  up in that list. Nothing the draft does not offer the person is a field of
  the page: no identity, links, HTML body, conversation or key.

  ## Attributes

    * `id`, `scope` (the viewer's `PhoenixKit.Users.Auth.Scope`), `draft`
      (a `ComposeDraft`) — required; a new draft starts the form afresh
    * `around_send`, `authorize_attachments`, `recipient_sources` — the host's
      callbacks and recipient sources, as for the pipeline
    * `attachment_picker` — an optional slot for the host's file picker

  ## Recipients

  Each line (To, Cc, Bcc) holds chips — server-side structures with the label,
  the address and the route (`:internal` ones are marked). People are added
  from suggestions (`PhoenixKitInbox.RecipientSource.suggest_all/4` over the
  module's own members and the host's `recipient_sources`, on the draft's
  `:context`) or by hand. A suggestion is named by its id in the list the
  server made; a typed address is an outside one (`:email`), and one that
  names a person or mailbox inside is refused with "choose them from the
  list". Doubles within a line are dropped; a line stops at the pipeline's
  limit (20 To, 5 Cc, 5 Bcc). With host sources, a button lists their people
  without a query.

  Without `Scope.can?(scope, "inbox")` the component renders an empty
  container and ignores every event.

  ## The send

  "Send" adds what was typed in a recipient field and not yet added (a field
  that cannot be added stops the send, its reason shown at the field), builds
  the draft from the form's own state — the chips, the host's files that were
  left, the own uploads — and runs `ComposePipeline.run/4` (the host's
  `around_send` inside it) in a task under `PhoenixKitInbox.TaskSupervisor`,
  not linked to the page: leaving or crashing the page does not cut it. A
  second send while one runs, or after one went, is ignored by the server.
  The answer comes back by `send_update` to the page; if the page is gone it
  is lost, the letter is not. A send that is killed, or takes five minutes,
  is reported as interrupted. A refusal shows its message (the host's own words only
  as `{:error, {:refused, text}}` from its `around_send`, see
  `ComposePipeline`; any other text, or a reason with no message, shows as
  "could not be sent");
  the button works again and the **same idempotency key** is kept, so a retry
  is the same letter. The form issues a fresh key whenever it is opened (a
  new component or a new draft) and replaces any `:idempotency_key` of the
  draft. Cancel is ignored while a send runs. Above the button, one line says
  who gets the letter, and — for outside addresses — where the host's
  `outbound_filter` would send it (`Outbound.preview/2`, nothing is sent).

  ## Messages to the parent LiveView

    * `{:inbox_compose, id, :cancelled}`
    * `{:inbox_compose, id, {:sent, %Message{}}}`
  """

  use PhoenixKitWeb, :live_component
  use Gettext, backend: PhoenixKitInbox.Gettext

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitInbox.Attachments
  alias PhoenixKitInbox.Errors
  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Outbound
  alias PhoenixKitInbox.RecipientSource
  alias PhoenixKitInbox.RecipientSources.Members
  alias PhoenixKitInbox.Schemas.Message
  alias PhoenixKitInbox.Signatures
  alias PhoenixKitInbox.Web.Components.ComposeDraft
  alias PhoenixKitInbox.Web.Components.ComposePipeline

  require Logger

  @blocks ~w(cc bcc signature)
  # How long a send may run before the page stops waiting for it. A send that
  # is slow, not lost, still lands; a retry with the same key is the same letter.
  # (`config :phoenix_kit_inbox, :compose_send_timeout` changes it, for tests.)
  @send_timeout :timer.minutes(5)
  @replay_margin 2
  @roles ~w(to cc bcc)
  @subject_max 500
  @query_max 320
  @typed_shown 8
  @picker_shown 30
  @email_shape ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/u

  # ── the component ───────────────────────────────────────────────────────────

  @impl true
  def mount(socket) do
    {:ok,
     allow_upload(socket, :attachments,
       accept: :any,
       max_entries: Attachments.max_files(),
       max_file_size: Attachments.max_upload_bytes(),
       auto_upload: true,
       progress: &upload_progress/3
     )}
  end

  # The browser's change event is the early check; this one holds too, wherever
  # an upload came from.
  defp upload_progress(:attachments, _entry, socket), do: {:noreply, limit_uploads(socket)}

  @impl true
  # The send task answers the component that started it, by send_update. An
  # answer to an attempt that is no longer the current one is not for this page.
  def update(%{send_result: {ref, result}}, %{assigns: %{send_ref: ref}} = socket),
    do: {:ok, finish_send(socket, result)}

  def update(%{send_lost: ref}, %{assigns: %{send_ref: ref, sending: true}} = socket) do
    {:ok,
     assign(socket,
       sending: false,
       error: gettext("Sending was interrupted. Check the sent mail before sending again.")
     )}
  end

  def update(%{send_result: _}, socket), do: {:ok, socket}
  def update(%{send_lost: _}, socket), do: {:ok, socket}

  def update(assigns, socket) do
    socket =
      socket
      |> assign(Map.take(assigns, ~w(id scope around_send authorize_attachments)a))
      |> assign(:recipient_sources, list_of(Map.get(assigns, :recipient_sources)))
      |> assign(:attachment_picker, list_of(Map.get(assigns, :attachment_picker)))
      |> then(&assign(&1, :allowed?, Scope.can?(&1.assigns.scope, "inbox")))

    draft = normalize_draft(assigns[:draft] || socket.assigns[:source_draft])
    scope_changed? = socket.assigns[:options_scope] != socket.assigns.scope

    cond do
      not socket.assigns.allowed? -> {:ok, socket}
      # A letter on its way is not the parent's to take back: its text, its
      # key and its answer stay until it is over.
      draft != socket.assigns[:source_draft] and socket.assigns[:sending] == true -> {:ok, socket}
      draft != socket.assigns[:source_draft] -> {:ok, open_draft(socket, draft)}
      scope_changed? -> {:ok, socket |> assign_sender(socket.assigns.from) |> refresh_summary()}
      true -> {:ok, socket}
    end
  end

  # An attribute a host leaves out or sets to nil is an empty list.
  defp list_of(list) when is_list(list), do: list
  defp list_of(_other), do: []

  defp normalize_draft(%ComposeDraft{} = draft), do: draft

  defp normalize_draft(map) when is_map(map),
    do: struct(ComposeDraft, Map.drop(map, [:__struct__]))

  defp normalize_draft(_), do: %ComposeDraft{}

  # A draft the form has not seen: everything it starts from is read again.
  defp open_draft(socket, %ComposeDraft{} = draft) do
    {to, seq} = chips(draft.to, "to", 1)
    {cc, seq} = chips(draft.cc, "cc", seq)
    {bcc, seq} = chips(draft.bcc, "bcc", seq)
    recipients = %{to: to, cc: cc, bcc: bcc}

    socket
    |> assign(
      source_draft: draft,
      subject: text(draft.subject),
      body: text(draft.body),
      recipients: recipients,
      chip_seq: seq,
      inputs: %{to: "", cc: "", bcc: ""},
      list: nil,
      list_seq: 0,
      recipient_error: nil,
      host_files: host_files(draft.attachments),
      picked: [],
      file_seq: length(List.wrap(draft.attachments)) + 1,
      files_error: nil,
      idempotency_key: UUIDv7.generate(),
      sending: false,
      sent: false,
      replayed: false,
      send_ref: nil,
      send_started: nil,
      summary: nil,
      from_error: nil,
      open: %{cc: recipients.cc != [], bcc: recipients.bcc != [], signature: false},
      signature_uuid: "",
      signature_block: "",
      error: nil
    )
    |> assign_sender(choice_key(draft.from))
    |> refresh_summary()
  end

  defp text(value) when is_binary(value), do: value
  defp text(_), do: ""

  # ── recipients (server structures; the browser only names them) ─────────────

  # The chips of a draft's line, keyed "<role>-<n>" from `from`; also the next
  # free number. A key is only ever handed out once, so one that was removed
  # cannot name a later chip.
  defp chips(list, role, from) when is_list(list) do
    list
    |> Enum.flat_map(&chip/1)
    |> Enum.map_reduce(from, fn chip, n -> {Map.put(chip, :key, "#{role}-#{n}"), n + 1} end)
  end

  defp chips(_other, _role, from), do: {[], from}

  # What the pipeline reads as a recipient, the form reads: atom or string
  # keys, a bare text for an outside address. A field left empty names nobody
  # and is dropped. Anything else that gives no address (a user who is gone,
  # an entry that is no recipient) stays as a chip with `address: nil`, shown
  # as an error: a recipient is never lost silently, and never sent without.
  defp chip(text) when is_binary(text), do: chip(%{address: text})

  defp chip(%{} = entry) when not is_struct(entry) do
    route = if field(entry, :route) in [:internal, "internal"], do: :internal, else: :email

    user =
      if is_binary(field(entry, :user)) and field(entry, :user) != "", do: field(entry, :user)

    address = field(entry, :address)
    label = field(entry, :label)

    cond do
      is_binary(address) and String.trim(address) != "" ->
        [%{user: user, address: String.trim(address), label: blank_to_nil(label), route: route}]

      user ->
        [
          %{
            user: user,
            address: resolved_address(user, route),
            label: blank_to_nil(label),
            route: route
          }
        ]

      blank_entry?(entry) ->
        []

      true ->
        [%{user: nil, address: nil, label: blank_to_nil(label), route: route}]
    end
  end

  defp chip(_), do: [%{user: nil, address: nil, label: nil, route: :email}]

  defp blank_entry?(entry) do
    values = [field(entry, :user), field(entry, :address)]
    Enum.any?(values, &is_binary/1) and Enum.all?(values, &(is_nil(&1) or String.trim(&1) == ""))
  end

  # A key of a map that is the draft's (atoms) or the browser's (strings).
  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp unresolved?(chip), do: is_nil(chip.address)

  # Nothing can be sent while a chip has no address, or while the sender of
  # the outside mail is not chosen.
  defp blocked?(assigns) do
    assigns.from_error != nil or
      Enum.any?([:to, :cc, :bcc], fn role ->
        Enum.any?(assigns.recipients[role], &unresolved?/1)
      end)
  end

  defp resolved_address(user, route) do
    case Mailboxes.recipient_address(user, route) do
      {:ok, address} -> address
      {:error, _} -> nil
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: String.trim(value)
  end

  defp blank_to_nil(_), do: nil

  defp chip_text(%{label: label}) when is_binary(label), do: label
  defp chip_text(%{address: address}) when is_binary(address), do: address
  defp chip_text(_), do: gettext("Unknown recipient")

  # ── who it is from ──────────────────────────────────────────────────────────

  # What the person may send as, from their rights: their own mailbox, the
  # shared ones they may write to, the identities they may use. A choice in the
  # browser is only ever a key into this list.
  defp from_options(scope) do
    with {:ok, user_uuid} <- Mailboxes.scope_user_uuid(scope),
         {:ok, personal} <- Mailboxes.ensure_user_mailbox(scope.user) do
      accessible = Mailboxes.list_accessible_mailboxes(user_uuid)

      shared =
        for %{kind: "shared"} = mailbox <- accessible,
            Mailboxes.access_level(mailbox, user_uuid) in ~w(write admin) do
          option({:mailbox, mailbox.uuid}, mailbox.name, mailbox)
        end

      identities =
        for identity <- Identities.list_usable(scope),
            mailbox = identity_mailbox(identity, personal, accessible),
            mailbox != nil do
          option(
            {:identity, identity.identity_uuid},
            "#{identity.label} <#{identity.from_address}>",
            mailbox
          )
        end

      name = Mailboxes.user_display_name(scope.user)

      [option(:user_default, gettext("%{name} (personal)", name: name), personal)] ++
        shared ++ identities
    else
      _ -> []
    end
  end

  defp identity_mailbox(%{mailbox_uuid: nil}, personal, _accessible), do: personal

  defp identity_mailbox(%{mailbox_uuid: uuid}, _personal, accessible),
    do: Enum.find(accessible, &(&1.uuid == uuid))

  defp option(choice, label, mailbox) do
    %{
      key: choice_key(choice),
      choice: choice,
      label: label,
      mailbox: mailbox,
      personal?: mailbox != nil and mailbox.kind == "user"
    }
  end

  defp choice_key(:user_default), do: "user_default"
  defp choice_key({:mailbox, uuid}) when is_binary(uuid), do: "mailbox:" <> uuid
  defp choice_key({:identity, uuid}) when is_binary(uuid), do: "identity:" <> uuid
  defp choice_key(_), do: "user_default"

  # Reads the options and takes `key` if it is one of them; the host's choice
  # that the person cannot use is shown as unavailable (the send refuses it).
  defp assign_sender(socket, key) do
    options = from_options(socket.assigns.scope)
    draft = socket.assigns.source_draft

    {options, key} =
      cond do
        Enum.any?(options, &(&1.key == key)) -> {options, key}
        key == choice_key(draft.from) -> {options ++ [unavailable(draft.from)], key}
        true -> {options, options |> List.first(%{key: "user_default"}) |> Map.fetch!(:key)}
      end

    socket
    |> assign(from_options: options, from: key, options_scope: socket.assigns.scope)
    |> assign_signatures()
  end

  defp unavailable(choice) do
    %{
      key: choice_key(choice),
      choice: choice,
      label: gettext("Unavailable sender"),
      mailbox: nil,
      personal?: false
    }
  end

  defp current_option(%{from_options: options, from: key}),
    do: Enum.find(options, &(&1.key == key))

  # The signatures of the mailbox the letter goes out from.
  defp assign_signatures(socket) do
    signatures =
      case current_option(socket.assigns) do
        %{mailbox: %{uuid: uuid}} -> Signatures.list(uuid)
        _ -> []
      end

    selected = socket.assigns[:signature_uuid]
    selected = if Enum.any?(signatures, &(&1.uuid == selected)), do: selected, else: ""
    assign(socket, signatures: signatures, signature_uuid: selected)
  end

  defp editable?(%{source_draft: %{from_editable: editable}}), do: editable != false

  defp reply_to(%{source_draft: draft}),
    do: blank_to_nil(draft.reply_to_trusted || draft.reply_to)

  # ── events ──────────────────────────────────────────────────────────────────

  @impl true
  # A viewer without the module's right has nothing here to act on.
  def handle_event(_event, _params, %{assigns: %{allowed?: false}} = socket),
    do: {:noreply, socket}

  def handle_event("select_from", %{"from" => key}, socket) when is_binary(key) do
    if editable?(socket.assigns) and Enum.any?(socket.assigns.from_options, &(&1.key == key)),
      do:
        {:noreply,
         socket |> assign(from: key, error: nil) |> assign_signatures() |> refresh_summary()},
      else: {:noreply, socket}
  end

  def handle_event("toggle", %{"block" => block}, socket) when block in @blocks,
    do: {:noreply, toggle(socket, String.to_existing_atom(block))}

  def handle_event("select_signature", %{"signature" => uuid}, socket) when is_binary(uuid) do
    signatures = socket.assigns.signatures

    cond do
      uuid == "" ->
        {:noreply, switch_signature(socket, nil)}

      signature = Enum.find(signatures, &(&1.uuid == uuid)) ->
        {:noreply, switch_signature(socket, signature)}

      true ->
        {:noreply, socket}
    end
  end

  # Typing in a line's field: the suggestions for it, from the server's sources.
  def handle_event("suggest", %{"role" => role, "query" => query}, socket)
      when is_binary(role) and is_binary(query) do
    case role_atom(role) do
      {:ok, role} -> {:noreply, suggest(socket, role, query)}
      :error -> {:noreply, socket}
    end
  end

  # Enter in a line's field: what was typed is an outside address or nothing.
  def handle_event("add", %{"role" => role, "query" => text}, socket)
      when is_binary(role) and is_binary(text) do
    case role_atom(role) do
      {:ok, role} -> {:noreply, add_typed(socket, role, text)}
      :error -> {:noreply, socket}
    end
  end

  # A suggestion of the list the server made, named by its id and nothing else:
  # the person, the route and the line all come from the server's side.
  def handle_event("pick", %{"id" => id}, socket) when is_binary(id) do
    with %{role: role, items: items} <- socket.assigns.list,
         %{entry: entry} <- Enum.find(items, &(&1.id == id)) do
      {:noreply, add_entry(socket, role, entry)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("remove", %{"key" => key}, socket) when is_binary(key) do
    recipients = socket.assigns.recipients

    case Enum.find([:to, :cc, :bcc], &has_chip?(recipients[&1], key)) do
      nil ->
        {:noreply, socket}

      role ->
        line = Enum.reject(recipients[role], &(&1.key == key))

        {:noreply,
         socket
         |> assign(recipients: Map.put(recipients, role, line), recipient_error: nil)
         |> refresh_summary()}
    end
  end

  def handle_event("toggle_picker", %{"role" => role}, socket) when is_binary(role) do
    with {:ok, role} <- role_atom(role),
         [_ | _] <- socket.assigns.recipient_sources do
      case socket.assigns.list do
        %{role: ^role, kind: :picker} ->
          {:noreply, assign(socket, list: nil, recipient_error: nil)}

        _ ->
          {:noreply, open_picker(socket, role)}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  # Only what the draft holds can be taken off, by the key the server gave it.
  def handle_event("remove_attachment", %{"key" => key}, socket) when is_binary(key) do
    %{host_files: host, picked: picked} = socket.assigns

    {:noreply,
     assign(socket,
       host_files: Enum.reject(host, &(&1.key == key)),
       picked: Enum.reject(picked, &(&1.key == key)),
       files_error: nil
     )}
  end

  # The host's picker names files by uuid; they count once the host's callback
  # has vouched for them (the send asks it again).
  def handle_event("pick_attachments", %{"uuids" => uuids}, socket) when is_list(uuids),
    do: {:noreply, pick(socket, uuids)}

  def handle_event("validate_upload", _params, socket),
    do: {:noreply, limit_uploads(socket)}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) when is_binary(ref) do
    if Enum.any?(socket.assigns.uploads.attachments.entries, &(&1.ref == ref)),
      do: {:noreply, cancel_upload(socket, :attachments, ref)},
      else: {:noreply, socket}
  end

  def handle_event("change", params, socket) do
    {:noreply,
     socket
     |> keep(:subject, params["subject"])
     |> keep(:body, params["body"])}
  end

  # One send per opening at a time, and none after one went: the server says
  # so, whatever the button looked like in the browser.
  def handle_event("submit", _params, %{assigns: %{sending: true}} = socket),
    do: {:noreply, socket}

  def handle_event("submit", _params, %{assigns: %{sent: true}} = socket),
    do: {:noreply, socket}

  def handle_event("submit", params, socket) do
    socket =
      socket
      |> keep(:subject, params["subject"])
      |> keep(:body, params["body"])
      |> assign(error: nil)
      |> add_pending_input()

    if socket.assigns.recipient_error || blocked?(socket.assigns),
      do: {:noreply, socket},
      else: {:noreply, start_send(socket)}
  end

  # A running send is not the form's to take back: the page stays until it is done.
  def handle_event("cancel", _params, %{assigns: %{sending: true}} = socket),
    do: {:noreply, socket}

  def handle_event("cancel", _params, socket) do
    send(self(), {:inbox_compose, socket.assigns.id, :cancelled})
    {:noreply, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp keep(socket, key, value) when is_binary(value), do: assign(socket, key, value)
  defp keep(socket, _key, _value), do: socket

  # ── the send ────────────────────────────────────────────────────────────────

  # What was typed in a line's field and not added is added now, by the rules
  # of adding; the first that cannot be added stops the send, and its reason
  # shows at its field. A recipient is never dropped silently.
  defp add_pending_input(socket) do
    Enum.reduce(shown_roles(socket), socket, fn role, acc ->
      text = acc.assigns.inputs[role]

      if acc.assigns.recipient_error || String.trim(text) == "",
        do: acc,
        else: add_typed(acc, role, text)
    end)
  end

  # The lines the page shows: To always, Cc and Bcc while their block is open.
  # What sits in the field of a line the person cannot see is not theirs to
  # have sent, nor to be stopped by.
  defp shown_roles(socket) do
    [:to | Enum.filter([:cc, :bcc], &socket.assigns.open[&1])]
  end

  # Everything the pipeline gets is made here from the server's state: the
  # draft with the chips and files the person left, the subject and text, the
  # sender's choice and the picks. The browser's params are read for the two
  # texts and nothing else.
  defp start_send(socket) do
    case collect_uploads(socket) do
      {:ok, uploads, links} ->
        run_send(socket, uploads, links)

      {:error, message} ->
        assign(socket, error: message)
    end
  end

  defp collect_uploads(socket) do
    case uploaded_entries(socket, :attachments) do
      {_done, [_ | _] = busy} ->
        if Enum.any?(busy, &(&1.valid? == false)),
          do: {:error, gettext("Remove the files that failed, then send again.")},
          else: {:error, Errors.message(:uploads_in_progress)}

      {[], []} ->
        {:ok, [], []}

      {_done, []} ->
        consumed =
          consume_uploaded_entries(socket, :attachments, fn %{path: path}, entry ->
            {:postpone, {entry.ref, path, entry.client_name, entry.client_type}}
          end)

        {entries, links} = own_uploads(consumed)
        {:ok, Enum.map(entries, &upload_attachment/1), links}
    end
  end

  # An upload's temporary file belongs to its upload channel and goes with the
  # page. The send gets a hard link of its own to each, so it survives the
  # page; where none can be made (another file system) the upload's own path.
  defp own_uploads(uploads) do
    Enum.map_reduce(uploads, [], fn {ref, path, name, type}, links ->
      link = Path.join(System.tmp_dir!(), "phoenix_kit_inbox_upload_#{UUIDv7.generate()}")

      case File.ln(path, link) do
        :ok -> {{ref, link, name, type}, [link | links]}
        {:error, _reason} -> {{ref, path, name, type}, links}
      end
    end)
  end

  defp upload_attachment({ref, path, name, type}) do
    filename = Attachments.clean_filename(name)

    %{
      id: "upload-#{ref}",
      path: path,
      filename: filename,
      name: filename,
      content_type: Attachments.safe_content_type(type)
    }
  end

  defp run_send(socket, uploads, links) do
    %{scope: scope, id: id} = socket.assigns
    host = for %{item: item} <- socket.assigns.host_files, do: item

    draft = %{
      chip_draft(socket)
      | attachments: host ++ uploads,
        idempotency_key: socket.assigns.idempotency_key
    }

    params =
      %{"subject" => socket.assigns.subject, "body" => socket.assigns.body}
      |> Map.put("from", socket.assigns.from)
      |> put_picks(socket.assigns.picked)

    callbacks =
      for key <- ~w(around_send authorize_attachments)a,
          fun = socket.assigns[key],
          into: %{},
          do: {key, fun}

    ref = System.unique_integer([:positive])

    case start_task(scope, id, ref, params, draft, callbacks, links) do
      :ok ->
        assign(socket, sending: true, send_ref: ref, send_started: DateTime.utc_now(), error: nil)

      :error ->
        Enum.each(links, &File.rm/1)
        assign(socket, error: Errors.message(:send_failed))
    end
  end

  # The host's draft with the recipients the person has now.
  defp chip_draft(socket) do
    %{source_draft: source, recipients: r} = socket.assigns

    %{
      source
      | to: Enum.map(r.to, &entry/1),
        cc: Enum.map(r.cc, &entry/1),
        bcc: Enum.map(r.bcc, &entry/1)
    }
  end

  defp put_picks(params, []), do: params

  defp put_picks(params, picked),
    do: Map.put(params, "added_attachments", Enum.map(picked, & &1.file_uuid))

  # A chip, as the pipeline takes a recipient from the draft.
  defp entry(chip) do
    chip
    |> Map.take([:user, :address, :label, :route])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # The send runs under the module's task supervisor, not linked to the page:
  # leaving or crashing the page between the commit and the external part must
  # not cut it. The answer finds its way back by send_update to the page's
  # pid, if it is still there. A second task watches the first: a send that
  # is killed, or takes longer than the timeout, is reported as lost.
  defp start_task(scope, id, ref, params, draft, callbacks, links) do
    page = self()

    supervisor =
      Application.get_env(
        :phoenix_kit_inbox,
        :compose_task_supervisor,
        PhoenixKitInbox.TaskSupervisor
      )

    work = fn ->
      result =
        try do
          ComposePipeline.run(scope, params, draft, callbacks)
        catch
          kind, reason ->
            # What failed, not what it carried: the text may name people.
            what = if is_struct(reason), do: inspect(reason.__struct__), else: "a #{kind}"
            Logger.error("[Inbox] a compose send ended with #{what}")
            {:error, :send_failed}
        after
          Enum.each(links, &File.rm/1)
        end

      Phoenix.LiveView.send_update(page, __MODULE__, id: id, send_result: {ref, result})
    end

    case Task.Supervisor.start_child(supervisor, work) do
      {:ok, worker} ->
        watch_worker(supervisor, worker, page, id, ref)
        :ok

      _refused ->
        :error
    end
  catch
    :exit, _reason -> :error
  end

  # The watcher is a courtesy: a worker that runs is the send, and the files
  # it was given are its own. Without a watcher the page waits for the
  # answer without a time limit, which is all that is lost.
  defp watch_worker(supervisor, worker, page, id, ref) do
    timeout = Application.get_env(:phoenix_kit_inbox, :compose_send_timeout, @send_timeout)

    case Task.Supervisor.start_child(supervisor, watch(worker, page, id, ref, timeout)) do
      {:ok, _watcher} ->
        :ok

      _refused ->
        Logger.warning("[Inbox] a compose send runs without a watcher: none could start")
    end
  catch
    :exit, _reason ->
      Logger.warning("[Inbox] a compose send runs without a watcher: none could start")
  end

  defp watch(worker, page, id, ref, timeout) do
    fn ->
      monitor = Process.monitor(worker)

      receive do
        {:DOWN, ^monitor, :process, ^worker, :normal} -> :ok
        {:DOWN, ^monitor, :process, ^worker, _reason} -> lost(page, id, ref)
      after
        timeout -> lost(page, id, ref)
      end
    end
  end

  defp lost(page, id, ref),
    do: Phoenix.LiveView.send_update(page, __MODULE__, id: id, send_lost: ref)

  # The same key answered with a letter that was there before this attempt
  # started: an earlier attempt went through unseen (the page was lost, the
  # answer was late), and what the person has just written was not sent. The
  # stored time has whole seconds, hence the margin.
  defp replayed?(%Message{inserted_at: %DateTime{} = stored}, %DateTime{} = started),
    do: DateTime.compare(stored, DateTime.add(started, -@replay_margin, :second)) == :lt

  defp replayed?(_message, _started), do: false

  defp finish_send(socket, {:ok, %Message{} = message}) do
    send(self(), {:inbox_compose, socket.assigns.id, {:sent, message}})

    assign(socket,
      sending: false,
      sent: true,
      replayed: replayed?(message, socket.assigns[:send_started]),
      send_ref: nil,
      error: nil
    )
  end

  defp finish_send(socket, {:error, reason}),
    do: assign(socket, sending: false, send_ref: nil, error: Errors.user_message(reason))

  defp finish_send(socket, _other),
    do: assign(socket, sending: false, send_ref: nil, error: Errors.message(:send_failed))

  # ── the line above the button ───────────────────────────────────────────────

  # Who gets it, as the person sees it — and, for the outside addresses, where
  # the host's filter would really send it (`Outbound.preview/2`; nothing is
  # sent). A filter that refuses or fails leaves the plain line.
  defp refresh_summary(socket) do
    %{recipients: r} = socket.assigns
    people = r.to ++ r.cc ++ r.bcc
    identity = effective_identity(socket)
    socket = assign(socket, :from_error, from_error(identity))

    summary =
      if people == [] do
        nil
      else
        {outside, unchecked?} = outside_addresses(socket, identity)

        %{
          from: socket.assigns |> current_option() |> then(&(&1 && &1.label)),
          to: Enum.map(r.to, &chip_text/1),
          cc: length(r.cc),
          bcc: length(r.bcc),
          outside: outside,
          unchecked: unchecked?,
          sender_as: sender_as(people, identity)
        }
      end

    assign(socket, :summary, summary)
  end

  # The sender an outside letter would go out as, worked out by the pipeline
  # as the send works it out: what the line says, what the filter is asked
  # with, and — when it cannot be worked out — what holds the send back.
  defp effective_identity(socket) do
    ComposePipeline.effective_identity(
      socket.assigns.scope,
      chip_draft(socket),
      %{"from" => socket.assigns.from}
    )
  end

  defp from_error({:error, :identity_required}), do: Errors.message(:identity_required)
  defp from_error(_other), do: nil

  defp sender_as(people, {:ok, %{from_address: address} = identity}) when is_binary(address) do
    if Enum.any?(people, &(&1.route == :email and is_binary(&1.address))) do
      case identity[:from_name] do
        name when is_binary(name) and name != "" -> "#{name} <#{address}>"
        _ -> address
      end
    end
  end

  defp sender_as(_people, _identity), do: nil

  # {where the filter would send it (nil when as typed), whether the filter
  # could not be asked}.
  defp outside_addresses(socket, identity) do
    r = socket.assigns.recipients

    typed =
      for role <- [:to, :cc, :bcc],
          c <- r[role],
          c.route == :email,
          is_binary(c.address),
          do: {role, c}

    case typed do
      [] ->
        {nil, false}

      _ ->
        case Outbound.preview(preview_email(typed), preview_context(socket, identity)) do
          {:ok, email} -> {rewritten(email, typed), false}
          {:error, _reason} -> {nil, true}
        end
    end
  end

  defp rewritten(email, typed) do
    shown = Enum.map(email.to ++ email.cc ++ email.bcc, fn {_name, address} -> address end)
    asked = Enum.map(typed, fn {_role, c} -> c.address end)

    if Enum.sort(Enum.map(shown, &String.downcase/1)) ==
         Enum.sort(Enum.map(asked, &String.downcase/1)),
       do: nil,
       else: Enum.uniq(shown)
  end

  defp preview_email(typed) do
    Enum.reduce(typed, Swoosh.Email.new(), fn {role, chip}, email ->
      recipient = {chip.label || "", chip.address}

      case role do
        :to -> Swoosh.Email.to(email, recipient)
        :cc -> Swoosh.Email.cc(email, recipient)
        :bcc -> Swoosh.Email.bcc(email, recipient)
      end
    end)
  end

  defp preview_context(socket, identity) do
    %{
      kind: :message,
      integration_uuid: nil,
      user_uuid: socket.assigns.scope.user && to_string(socket.assigns.scope.user.uuid),
      identity_uuid: with({:ok, %{identity_uuid: uuid}} <- identity, do: uuid)
    }
  end

  defp summary_text(%{from: from, to: to} = summary) do
    [
      base_text(from || "?", to),
      summary.cc > 0 && ngettext("%{count} in copy", "%{count} in copy", summary.cc),
      summary.bcc > 0 && ngettext("%{count} hidden", "%{count} hidden", summary.bcc),
      summary.sender_as &&
        gettext("outside mail goes out as %{sender}", sender: summary.sender_as),
      summary.outside &&
        gettext("outside mail goes to %{addresses}", addresses: Enum.join(summary.outside, ", ")),
      summary.unchecked && gettext("Where the outside mail goes could not be checked.")
    ]
    |> Enum.filter(& &1)
    |> Enum.join("; ")
  end

  defp base_text(from, []), do: gettext("From %{from}", from: from)

  defp base_text(from, to),
    do: gettext("From %{from} → %{to}", from: from, to: Enum.join(to, ", "))

  # ── attachments ─────────────────────────────────────────────────────────────

  defp host_files(list) when is_list(list) do
    for {%{} = item, n} <- Enum.with_index(list, 1),
        not is_struct(item),
        do: %{key: "h-#{n}", item: item}
  end

  defp host_files(_), do: []

  defp held_uuids(%{host_files: host, picked: picked}) do
    from_host =
      for %{item: item} <- host,
          uuid = Map.get(item, :file_uuid) || Map.get(item, "file_uuid"),
          is_binary(uuid),
          do: String.downcase(uuid)

    from_host ++ Enum.map(picked, & &1.file_uuid)
  end

  defp file_count(socket) do
    %{host_files: host, picked: picked, uploads: uploads} = socket.assigns
    length(host) + length(picked) + length(uploads.attachments.entries)
  end

  defp pick(socket, raw) do
    case cast_uuids(raw) do
      {:ok, uuids} -> pick_new(socket, uuids -- held_uuids(socket.assigns))
      :error -> socket
    end
  end

  defp cast_uuids(raw) when length(raw) <= 50 do
    Enum.reduce_while(raw, {:ok, []}, fn value, {:ok, acc} ->
      with true <- is_binary(value), {:ok, uuid} <- Ecto.UUID.cast(value) do
        {:cont, {:ok, Enum.uniq(acc ++ [uuid])}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp cast_uuids(_), do: :error

  defp pick_new(socket, []), do: socket

  defp pick_new(socket, uuids) do
    max = Attachments.max_files()

    if file_count(socket) + length(uuids) > max do
      assign(socket, files_error: Errors.message({:too_many_attachments, max}))
    else
      case ComposePipeline.authorize_picks(
             socket.assigns.scope,
             socket.assigns.source_draft,
             uuids,
             socket.assigns[:authorize_attachments]
           ) do
        {:ok, items} -> add_picks(socket, uuids, items)
        {:error, reason} -> assign(socket, files_error: Errors.message(reason))
      end
    end
  end

  # A pick is shown under the name the host gave with its yes, else by a
  # short label of the file's id.
  defp add_picks(socket, uuids, items) do
    {picks, seq} =
      Enum.map_reduce(uuids, socket.assigns.file_seq, fn uuid, n ->
        name = Enum.find_value(items, &(&1.file_uuid == uuid && is_binary(&1.name) && &1.name))
        {%{key: "p-#{n}", file_uuid: uuid, name: name}, n + 1}
      end)

    assign(socket, picked: socket.assigns.picked ++ picks, file_seq: seq, files_error: nil)
  end

  # An upload that would take the message over its count is taken off again.
  defp limit_uploads(socket) do
    max = Attachments.max_files()
    entries = socket.assigns.uploads.attachments.entries
    over = file_count(socket) - max

    if over > 0 do
      entries
      |> Enum.take(-over)
      |> Enum.reduce(socket, &cancel_upload(&2, :attachments, &1.ref))
      |> assign(files_error: Errors.message({:too_many_attachments, max}))
    else
      assign(socket, files_error: nil)
    end
  end

  # ── the recipients' lines ───────────────────────────────────────────────────

  defp role_atom(role) when role in @roles, do: {:ok, String.to_existing_atom(role)}
  defp role_atom(_), do: :error

  defp has_chip?(chips, key), do: Enum.any?(chips, &(&1.key == key))

  # What the module knows of its own people, then whatever the host brought.
  defp all_sources(socket), do: Enum.uniq([Members | socket.assigns.recipient_sources])

  defp context(socket) do
    case socket.assigns.source_draft.context do
      %{} = context -> context
      _ -> %{}
    end
  end

  defp suggest(socket, role, query) do
    query = String.slice(query, 0, @query_max)
    socket = assign(socket, inputs: Map.put(socket.assigns.inputs, role, query))

    entries =
      if String.trim(query) == "",
        do: [],
        else:
          socket
          |> all_sources()
          |> RecipientSource.suggest_all(socket.assigns.scope, context(socket), query)
          |> Enum.take(@typed_shown)

    socket |> assign(recipient_error: nil) |> assign_list(role, :typed, entries)
  end

  defp open_picker(socket, role) do
    entries =
      socket.assigns.recipient_sources
      |> RecipientSource.suggest_all(socket.assigns.scope, context(socket), "")
      |> Enum.take(@picker_shown)

    socket |> assign(recipient_error: nil) |> assign_list(role, :picker, entries)
  end

  # Every suggestion gets an id of this list only; a new list voids the old ids.
  defp assign_list(socket, _role, :typed, []), do: assign(socket, list: nil)

  defp assign_list(socket, role, kind, entries) do
    {items, seq} =
      Enum.map_reduce(entries, socket.assigns.list_seq, fn entry, n ->
        {%{id: "s-#{n + 1}", entry: entry}, n + 1}
      end)

    assign(socket, list: %{role: role, kind: kind, items: items}, list_seq: seq)
  end

  defp add_typed(socket, role, text) do
    text = String.trim(text)

    if text == "" do
      socket
    else
      case typed_entry(socket.assigns.scope, text) do
        {:ok, entry} -> add_entry(socket, role, entry)
        {:error, message} -> assign(socket, recipient_error: {role, message})
      end
    end
  end

  # Typed by hand, a recipient is an outside address. One that names a person
  # or mailbox inside is not taken (the send would refuse it): it is to be
  # chosen from the list.
  defp typed_entry(scope, text) do
    cond do
      not ComposePipeline.valid_address?(text) ->
        {:error, gettext("That is not an email address.")}

      internal?(scope, text) ->
        {:error, Errors.message({:member_as_email, [text]})}

      not Regex.match?(@email_shape, text) ->
        {:error, gettext("That is not an email address.")}

      true ->
        {:ok, %{address: text, label: nil, route: :email}}
    end
  end

  defp internal?(scope, text) do
    match?([%{route: :internal}], Messages.resolve_recipient_routes(scope, [text]))
  end

  defp add_entry(socket, role, entry) do
    %{recipients: recipients, chip_seq: seq} = socket.assigns
    line = recipients[role]
    max = ComposePipeline.max_recipients(role)

    case chip(entry) do
      [%{address: address} = chip] when is_binary(address) ->
        cond do
          Enum.any?(line, &same_person?(&1, chip)) ->
            finish_add(socket, role)

          length(line) >= max ->
            assign(socket,
              recipient_error: {role, Errors.message({:too_many_recipients, role, max})}
            )

          true ->
            chip = Map.put(chip, :key, "#{role}-#{seq}")

            socket
            |> assign(
              recipients: Map.put(recipients, role, line ++ [chip]),
              chip_seq: seq + 1,
              open: Map.replace(socket.assigns.open, role, true)
            )
            |> finish_add(role)
        end

      _ ->
        socket
    end
  end

  defp finish_add(socket, role) do
    socket
    |> assign(
      inputs: Map.put(socket.assigns.inputs, role, ""),
      list: nil,
      recipient_error: nil
    )
    |> refresh_summary()
  end

  defp same_person?(%{user: user}, %{user: user}) when is_binary(user), do: true

  defp same_person?(%{address: a}, %{address: b}) when is_binary(a) and is_binary(b),
    do: String.downcase(a) == String.downcase(b)

  defp same_person?(_, _), do: false

  # A block holding people stays open: closing it would hide who gets the letter.
  defp toggle(socket, :signature) do
    if socket.assigns.signatures == [],
      do: socket,
      else: update(socket, :open, &Map.update!(&1, :signature, fn open -> not open end))
  end

  defp toggle(socket, role) do
    cond do
      socket.assigns.recipients[role] != [] -> socket
      socket.assigns.open[role] -> close_line(socket, role)
      true -> update(socket, :open, &Map.put(&1, role, true))
    end
  end

  # A closed line keeps nothing of what was typed in it.
  defp close_line(socket, role) do
    list = socket.assigns.list
    error = socket.assigns.recipient_error

    socket
    |> update(:open, &Map.put(&1, role, false))
    |> assign(
      inputs: Map.put(socket.assigns.inputs, role, ""),
      list: if(match?(%{role: ^role}, list), do: nil, else: list),
      recipient_error: if(match?({^role, _}, error), do: nil, else: error)
    )
  end

  # Swaps the signature block at the end of the text; an edited block stays.
  defp switch_signature(socket, signature) do
    %{body: body, signature_block: inserted} = socket.assigns

    case Signatures.swap_block(body, inserted, signature) do
      {:ok, body} ->
        assign(socket,
          body: body,
          signature_uuid: (signature && signature.uuid) || "",
          signature_block: Signatures.block(signature),
          error: nil
        )

      :edited ->
        assign(
          socket,
          :error,
          gettext("The signature in the message was edited, so it was left as it is.")
        )
    end
  end

  # ── rendering ───────────────────────────────────────────────────────────────

  @impl true
  def render(%{allowed?: false} = assigns) do
    ~H"""
    <div id={"compose-form-#{@id}"}></div>
    """
  end

  def render(assigns) do
    assigns =
      assigns
      |> assign(:option, current_option(assigns))
      |> assign(:editable?, editable?(assigns))
      |> assign(:reply_to, reply_to(assigns))
      |> assign(:subject_max, @subject_max)
      |> assign(:blocked?, blocked?(assigns))

    ~H"""
    <div id={"compose-form-#{@id}"} class="flex flex-col gap-3">
      <div id={"compose-#{@id}-from"} class="flex flex-col gap-1">
        <form
          :if={@editable? and length(@from_options) > 1}
          id={"compose-#{@id}-from-form"}
          phx-change="select_from"
          phx-target={@myself}
        >
          <.select
            id={"compose-#{@id}-from-select"}
            name="from"
            label={gettext("From")}
            value={@from}
            options={Enum.map(@from_options, &{&1.label, &1.key})}
            class="select-sm"
          />
        </form>
        <div :if={not (@editable? and length(@from_options) > 1)} class="flex flex-col gap-1">
          <span class="text-sm font-medium">{gettext("From")}</span>
          <span class="text-sm">{@option && @option.label}</span>
        </div>
        <p :if={@reply_to} id={"compose-#{@id}-reply-to"} class="text-xs text-base-content/60">
          {gettext("Replies go to %{address}", address: @reply_to)}
        </p>
        <p
          :if={@from_error}
          id={"compose-#{@id}-from-error"}
          role="alert"
          class="text-xs text-error"
        >
          {@from_error}
        </p>
        <div
          :if={@option && @option.personal?}
          id={"compose-#{@id}-personal-note"}
          role="status"
          class="alert alert-warning alert-soft py-1 text-sm"
        >
          <.icon name="hero-eye-slash" class="w-4 h-4" />
          <span>{gettext("From your personal mailbox: only you will see this letter.")}</span>
        </div>
      </div>

      <div
        :if={@replayed}
        id={"compose-#{@id}-replay-note"}
        role="status"
        class="alert alert-info alert-soft py-2 text-sm"
      >
        <.icon name="hero-information-circle" class="w-5 h-5" />
        <span>
          {gettext("This message was already sent earlier, with its earlier text. Nothing was sent again.")}
        </span>
      </div>

      <div :if={@error} role="alert" class="alert alert-error alert-soft py-2 text-sm">
        <.icon name="hero-exclamation-circle" class="w-5 h-5" />
        <span>{@error}</span>
      </div>

      <.recipients
        id={@id}
        role="to"
        label={gettext("To")}
        line={line(assigns, :to)}
        target={@myself}
      />

      <div class="flex flex-wrap items-center gap-1" role="group" aria-label={gettext("More fields")}>
        <.block_button id={@id} block="cc" label={gettext("+ Cc")} open={@open.cc} target={@myself} />
        <.block_button
          id={@id}
          block="bcc"
          label={gettext("+ Bcc")}
          open={@open.bcc}
          target={@myself}
        />
        <.block_button
          :if={@signatures != []}
          id={@id}
          block="signature"
          label={gettext("Signature")}
          open={@open.signature}
          target={@myself}
        />
      </div>

      <.recipients
        :if={@open.cc}
        id={@id}
        role="cc"
        label={gettext("Cc")}
        line={line(assigns, :cc)}
        target={@myself}
      />
      <.recipients
        :if={@open.bcc}
        id={@id}
        role="bcc"
        label={gettext("Bcc")}
        line={line(assigns, :bcc)}
        target={@myself}
      />

      <form
        :if={@open.signature and @signatures != []}
        id={"compose-#{@id}-signature-form"}
        phx-change="select_signature"
        phx-target={@myself}
      >
        <div id={"compose-#{@id}-signature"}>
          <.select
            id={"compose-#{@id}-signature-select"}
            name="signature"
            label={gettext("Signature")}
            value={@signature_uuid}
            options={[{gettext("No signature"), ""} | Enum.map(@signatures, &{&1.label, &1.uuid})]}
            class="select-sm"
          />
        </div>
      </form>

      <.form
        for={%{}}
        id={"compose-#{@id}-form"}
        phx-change="change"
        phx-submit="submit"
        phx-target={@myself}
        class="flex flex-col gap-3"
      >
        <.input
          id={"compose-#{@id}-subject"}
          name="subject"
          type="text"
          label={gettext("Subject")}
          value={@subject}
          maxlength={@subject_max}
        />
        <.textarea
          id={"compose-#{@id}-body"}
          name="body"
          label={gettext("Message")}
          value={@body}
          rows="10"
        />
        <%!-- Enter in the subject must not send the letter. A browser answers
        it by clicking the form's first submit button, and by doing nothing if
        that one is disabled; the real Send button is outside the form (bound
        to it by form=), so the form holds this dead one, first. --%>
        <button type="submit" class="hidden" disabled tabindex="-1" aria-hidden="true"></button>
      </.form>

      <div id={"compose-#{@id}-attachments"} class="flex flex-col gap-1">
        <span class="text-sm font-medium" id={"compose-#{@id}-attachments-label"}>
          {gettext("Attachments")}
        </span>
        <ul
          class="flex flex-wrap items-center gap-1"
          aria-labelledby={"compose-#{@id}-attachments-label"}
        >
          <.file_chip
            :for={file <- @host_files}
            id={"compose-#{@id}-file-#{file.key}"}
            name={attachment_name(file.item)}
            key={file.key}
            target={@myself}
          />
          <.file_chip
            :for={file <- @picked}
            id={"compose-#{@id}-file-#{file.key}"}
            name={file.name || gettext("File %{id}", id: String.slice(file.file_uuid, 0, 8))}
            key={file.key}
            target={@myself}
          />
          <li
            :for={entry <- @uploads.attachments.entries}
            id={"compose-#{@id}-upload-#{entry.ref}"}
            data-upload
            class={["badge badge-outline gap-1", entry.valid? == false && "badge-error"]}
          >
            <.icon name="hero-arrow-up-tray" class="w-3 h-3" />
            {Attachments.clean_filename(entry.client_name)}
            <span :if={entry.valid? and not entry.done?} class="text-xs">{entry.progress}%</span>
            <span :for={error <- upload_errors(@uploads.attachments, entry)} class="text-xs">
              {upload_error_text(error)}
            </span>
            <button
              type="button"
              class="btn btn-ghost btn-circle btn-xs size-4 min-h-0"
              aria-label={gettext("Cancel upload")}
              phx-click="cancel_upload"
              phx-value-ref={entry.ref}
              phx-target={@myself}
            >
              <.icon name="hero-x-mark" class="w-3 h-3" />
            </button>
          </li>
        </ul>
        <p
          :for={error <- upload_errors(@uploads.attachments)}
          class="text-xs text-error"
          role="alert"
        >
          {upload_error_text(error)}
        </p>
        <p
          :if={@files_error}
          id={"compose-#{@id}-files-error"}
          role="alert"
          class="text-xs text-error"
        >
          {@files_error}
        </p>
        <div class="flex flex-wrap items-center gap-1">
          <form
            id={"compose-#{@id}-upload-form"}
            phx-change="validate_upload"
            phx-target={@myself}
          >
            <label class="btn btn-ghost btn-xs btn-outline">
              <.icon name="hero-arrow-up-tray" class="w-3 h-3" />
              {gettext("Upload files")}
              <.live_file_input upload={@uploads.attachments} class="hidden" />
            </label>
          </form>
          {render_slot(@attachment_picker, %{target: @myself, event: "pick_attachments"})}
        </div>
      </div>

      <p
        :if={@summary}
        id={"compose-#{@id}-summary"}
        class="text-sm text-base-content/70"
        data-sending={@sending || nil}
      >
        {summary_text(@summary)}
      </p>

      <div class="flex justify-end gap-2">
        <.button
          type="button"
          variant="ghost"
          disabled={@sending}
          phx-click="cancel"
          phx-target={@myself}
        >
          {gettext("Cancel")}
        </.button>
        <.button
          type="submit"
          form={"compose-#{@id}-form"}
          variant="primary"
          disabled={@sending or @sent or @blocked?}
          aria-busy={to_string(@sending)}
        >
          {if @sending, do: gettext("Sending…"), else: gettext("Send")}
        </.button>
      </div>
    </div>
    """
  end

  # What one line of recipients shows: its chips, what is typed, the list under
  # it (when it is this line's) and the last refusal (when it was this line's).
  defp line(assigns, role) do
    list = if match?(%{role: ^role}, assigns.list), do: assigns.list

    error =
      case assigns.recipient_error do
        {^role, message} -> message
        _ -> if Enum.any?(assigns.recipients[role], &unresolved?/1), do: unresolved_message()
      end

    %{
      chips: assigns.recipients[role],
      query: assigns.inputs[role],
      list: list,
      error: error,
      picker?: assigns.recipient_sources != [],
      picker_open?: match?(%{kind: :picker}, list)
    }
  end

  defp unresolved_message,
    do:
      gettext(
        "A recipient here has no address, so nothing can be sent to them. Remove them to send."
      )

  attr(:id, :string, required: true)
  attr(:role, :string, required: true)
  attr(:label, :string, required: true)
  attr(:line, :map, required: true)
  attr(:target, :any, required: true)

  defp recipients(assigns) do
    ~H"""
    <div id={"compose-#{@id}-#{@role}"} class="flex flex-col gap-1">
      <label
        class="text-sm font-medium"
        id={"compose-#{@id}-#{@role}-label"}
        for={"compose-#{@id}-#{@role}-input"}
      >
        {@label}
      </label>
      <ul
        class="flex flex-wrap items-center gap-1"
        aria-labelledby={"compose-#{@id}-#{@role}-label"}
      >
        <li
          :for={chip <- @line.chips}
          id={"compose-#{@id}-chip-#{chip.key}"}
          class={["badge badge-outline gap-1", unresolved?(chip) && "badge-error"]}
          data-route={chip.route}
          data-unresolved={unresolved?(chip) || nil}
          title={chip.address}
        >
          <.internal_marker :if={chip.route == :internal} />
          {chip_text(chip)}
          <button
            type="button"
            class="btn btn-ghost btn-circle btn-xs size-4 min-h-0"
            aria-label={gettext("Remove %{name}", name: chip_text(chip))}
            phx-click="remove"
            phx-value-key={chip.key}
            phx-target={@target}
          >
            <.icon name="hero-x-mark" class="w-3 h-3" />
          </button>
        </li>
      </ul>
      <form
        id={"compose-#{@id}-#{@role}-form"}
        class="flex items-center gap-1"
        phx-change="suggest"
        phx-submit="add"
        phx-target={@target}
      >
        <input type="hidden" name="role" value={@role} />
        <.input
          id={"compose-#{@id}-#{@role}-input"}
          name="query"
          type="text"
          value={@line.query}
          placeholder={gettext("Name or email")}
          autocomplete="off"
          maxlength="320"
          phx-debounce="300"
          wrapper_class="grow"
          class="input-sm"
        />
        <.button :if={String.trim(@line.query) != ""} type="submit" variant="ghost" size="xs">
          {gettext("Add")}
        </.button>
      </form>
      <p
        :if={@line.error}
        id={"compose-#{@id}-#{@role}-error"}
        role="alert"
        class="text-xs text-error"
      >
        {@line.error}
      </p>
      <.suggestions :if={@line.list} id={@id} role={@role} list={@line.list} target={@target} />
      <div>
        <.button
          :if={@line.picker?}
          type="button"
          variant="ghost"
          size="xs"
          class="btn-outline"
          aria-expanded={to_string(@line.picker_open?)}
          phx-click="toggle_picker"
          phx-value-role={@role}
          phx-target={@target}
        >
          {gettext("+ From client or CRM addresses")}
        </.button>
      </div>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:role, :string, required: true)
  attr(:list, :map, required: true)
  attr(:target, :any, required: true)

  defp suggestions(assigns) do
    assigns = assign(assigns, :groups, groups(assigns.list.items))

    ~H"""
    <div
      id={"compose-#{@id}-#{@role}-suggestions"}
      class="flex flex-col gap-1 rounded-box border border-base-300 bg-base-100 p-1"
    >
      <p :if={@list.items == []} class="px-2 py-1 text-sm text-base-content/60">
        {gettext("No addresses found.")}
      </p>
      <div :for={{group, items} <- @groups} class="flex flex-col">
        <p :if={group} class="px-2 pt-1 text-xs font-medium text-base-content/60">{group}</p>
        <button
          :for={item <- items}
          type="button"
          class="btn btn-ghost btn-sm justify-start gap-2 font-normal"
          phx-click="pick"
          phx-value-id={item.id}
          phx-target={@target}
        >
          <.internal_marker :if={item.entry.route == :internal} />
          {chip_text(item.entry)}
          <span :if={item.entry[:label] && item.entry[:address]} class="text-xs text-base-content/60">
            {item.entry.address}
          </span>
        </button>
      </div>
    </div>
    """
  end

  defp internal_marker(assigns) do
    ~H"""
    <span data-internal-marker class="badge badge-info badge-soft badge-xs">
      {gettext("internal")}
    </span>
    """
  end

  # The items under their group's heading, in the order the groups first appear.
  defp groups(items) do
    items
    |> Enum.map(& &1.entry.group)
    |> Enum.uniq()
    |> Enum.map(fn group -> {group, Enum.filter(items, &(&1.entry.group == group))} end)
  end

  attr(:id, :string, required: true)
  attr(:block, :string, required: true)
  attr(:label, :string, required: true)
  attr(:open, :boolean, required: true)
  attr(:target, :any, required: true)

  defp block_button(assigns) do
    ~H"""
    <.button
      type="button"
      variant="ghost"
      size="xs"
      class={["btn-outline", @open && "btn-active"]}
      aria-pressed={to_string(@open)}
      phx-click="toggle"
      phx-value-block={@block}
      phx-target={@target}
    >
      {@label}
    </.button>
    """
  end

  attr(:id, :string, required: true)
  attr(:name, :string, required: true)
  attr(:key, :string, required: true)
  attr(:target, :any, required: true)

  defp file_chip(assigns) do
    ~H"""
    <li id={@id} data-file class="badge badge-outline gap-1">
      <.icon name="hero-paper-clip" class="w-3 h-3" />
      {@name}
      <button
        type="button"
        class="btn btn-ghost btn-circle btn-xs size-4 min-h-0"
        aria-label={gettext("Remove %{name}", name: @name)}
        phx-click="remove_attachment"
        phx-value-key={@key}
        phx-target={@target}
      >
        <.icon name="hero-x-mark" class="w-3 h-3" />
      </button>
    </li>
    """
  end

  defp upload_error_text(:too_large), do: gettext("Larger than the upload limit.")
  defp upload_error_text(:too_many_files), do: gettext("Too many files.")
  defp upload_error_text(:not_accepted), do: gettext("This file type is not accepted.")
  defp upload_error_text(_), do: gettext("The upload failed.")

  defp attachment_name(%{} = attachment) do
    Map.get(attachment, :name) || Map.get(attachment, :filename) || gettext("File")
  end

  defp attachment_name(_), do: gettext("File")
end
