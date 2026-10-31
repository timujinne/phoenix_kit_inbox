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

  Without `Scope.can?(scope, "inbox")` the component renders an empty
  container and ignores every event.

  ## Messages to the parent LiveView

    * `{:inbox_compose, id, :cancelled}`
  """

  use PhoenixKitWeb, :live_component
  use Gettext, backend: PhoenixKitInbox.Gettext

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Signatures
  alias PhoenixKitInbox.Web.Components.ComposeDraft

  @blocks ~w(cc bcc signature)
  @subject_max 500

  # ── the component ───────────────────────────────────────────────────────────

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(Map.take(assigns, ~w(id scope around_send authorize_attachments)a))
      |> assign(:recipient_sources, Map.get(assigns, :recipient_sources, []))
      |> assign(:attachment_picker, Map.get(assigns, :attachment_picker, []))
      |> then(&assign(&1, :allowed?, Scope.can?(&1.assigns.scope, "inbox")))

    draft = normalize_draft(assigns[:draft] || socket.assigns[:source_draft])
    scope_changed? = socket.assigns[:options_scope] != socket.assigns.scope

    cond do
      not socket.assigns.allowed? -> {:ok, socket}
      draft != socket.assigns[:source_draft] -> {:ok, open_draft(socket, draft)}
      scope_changed? -> {:ok, assign_sender(socket, socket.assigns.from)}
      true -> {:ok, socket}
    end
  end

  defp normalize_draft(%ComposeDraft{} = draft), do: draft

  defp normalize_draft(map) when is_map(map),
    do: struct(ComposeDraft, Map.drop(map, [:__struct__]))

  defp normalize_draft(_), do: %ComposeDraft{}

  # A draft the form has not seen: everything it starts from is read again.
  defp open_draft(socket, %ComposeDraft{} = draft) do
    recipients = %{
      to: chips(draft.to, "to", 1),
      cc: chips(draft.cc, "cc", 1),
      bcc: chips(draft.bcc, "bcc", 1)
    }

    socket
    |> assign(
      source_draft: draft,
      subject: text(draft.subject),
      body: text(draft.body),
      recipients: recipients,
      open: %{cc: recipients.cc != [], bcc: recipients.bcc != [], signature: false},
      signature_uuid: "",
      signature_block: "",
      error: nil
    )
    |> assign_sender(choice_key(draft.from))
  end

  defp text(value) when is_binary(value), do: value
  defp text(_), do: ""

  # ── recipients (server structures; the browser only names them) ─────────────

  defp chips(list, role, from) when is_list(list) do
    list
    |> Enum.flat_map(&chip/1)
    |> Enum.with_index(from)
    |> Enum.map(fn {chip, n} -> Map.put(chip, :key, "#{role}-#{n}") end)
  end

  defp chips(_other, _role, _from), do: []

  defp chip(%{} = entry) when not is_struct(entry) do
    route = if Map.get(entry, :route) == :internal, do: :internal, else: :email
    user = if is_binary(Map.get(entry, :user)), do: entry.user
    address = Map.get(entry, :address)
    label = Map.get(entry, :label)

    address =
      cond do
        is_binary(address) and address != "" -> address
        user -> resolved_address(user, route)
        true -> nil
      end

    if is_nil(address) and is_nil(user),
      do: [],
      else: [%{user: user, address: address, label: blank_to_nil(label), route: route}]
  end

  defp chip(_), do: []

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
  defp chip_text(_), do: "?"

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
      do: {:noreply, socket |> assign(from: key, error: nil) |> assign_signatures()},
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

  def handle_event("change", params, socket) do
    {:noreply,
     socket
     |> keep(:subject, params["subject"])
     |> keep(:body, params["body"])}
  end

  # Sending is wired in with the pipeline; until then Enter in a field must
  # not submit the page.
  def handle_event("submit", _params, socket), do: {:noreply, socket}

  def handle_event("cancel", _params, socket) do
    send(self(), {:inbox_compose, socket.assigns.id, :cancelled})
    {:noreply, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp keep(socket, key, value) when is_binary(value), do: assign(socket, key, value)
  defp keep(socket, _key, _value), do: socket

  # A block holding people stays open: closing it would hide who gets the letter.
  defp toggle(socket, :signature) do
    if socket.assigns.signatures == [],
      do: socket,
      else: update(socket, :open, &Map.update!(&1, :signature, fn open -> not open end))
  end

  defp toggle(socket, role) do
    if socket.assigns.recipients[role] == [],
      do: update(socket, :open, &Map.update!(&1, role, fn open -> not open end)),
      else: socket
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

      <div :if={@error} role="alert" class="alert alert-error alert-soft py-2 text-sm">
        <.icon name="hero-exclamation-circle" class="w-5 h-5" />
        <span>{@error}</span>
      </div>

      <.recipients id={@id} role="to" label={gettext("To")} chips={@recipients.to} />

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

      <.recipients :if={@open.cc} id={@id} role="cc" label={gettext("Cc")} chips={@recipients.cc} />
      <.recipients
        :if={@open.bcc}
        id={@id}
        role="bcc"
        label={gettext("Bcc")}
        chips={@recipients.bcc}
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
      </.form>

      <div id={"compose-#{@id}-attachments"} class="flex flex-col gap-1">
        <span class="text-sm font-medium" id={"compose-#{@id}-attachments-label"}>
          {gettext("Attachments")}
        </span>
        <ul
          class="flex flex-wrap items-center gap-1"
          aria-labelledby={"compose-#{@id}-attachments-label"}
        >
          <li
            :for={attachment <- @source_draft.attachments}
            class="badge badge-outline gap-1"
          >
            <.icon name="hero-paper-clip" class="w-3 h-3" />
            {attachment_name(attachment)}
          </li>
        </ul>
      </div>

      <div class="flex justify-end gap-2">
        <.button type="button" variant="ghost" phx-click="cancel" phx-target={@myself}>
          {gettext("Cancel")}
        </.button>
      </div>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:role, :string, required: true)
  attr(:label, :string, required: true)
  attr(:chips, :list, required: true)

  defp recipients(assigns) do
    ~H"""
    <div id={"compose-#{@id}-#{@role}"} class="flex flex-col gap-1">
      <span class="text-sm font-medium" id={"compose-#{@id}-#{@role}-label"}>{@label}</span>
      <ul
        class="flex flex-wrap items-center gap-1"
        aria-labelledby={"compose-#{@id}-#{@role}-label"}
      >
        <li
          :for={chip <- @chips}
          id={"compose-#{@id}-chip-#{chip.key}"}
          class="badge badge-outline gap-1"
          title={chip.address}
        >
          {chip_text(chip)}
        </li>
      </ul>
    </div>
    """
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

  defp attachment_name(%{} = attachment) do
    Map.get(attachment, :name) || Map.get(attachment, :filename) || gettext("File")
  end

  defp attachment_name(_), do: gettext("File")
end
