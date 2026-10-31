defmodule PhoenixKitInbox.Web.Components.ComposePipeline do
  @moduledoc """
  What a compose form's send does on the server. The browser's form params
  are untrusted: nothing in them is believed beyond what the host's draft
  (`PhoenixKitInbox.Web.Components.ComposeDraft`) and the person's own rights
  allow, and the message goes out through `PhoenixKitInbox.Messages.send_message/4`,
  which checks what is its to check (`write` on the mailbox, `inbox.send_external`
  for outside addresses) — this does not duplicate those checks, relax them or
  go around them.

      ComposePipeline.run(scope, form_params, draft, %{
        around_send: &MyHost.around_send/3,
        authorize_attachments: &MyHost.authorize_attachments/3
      })

  ## What the form may send (string keys; anything else is ignored)

    * `"from"` — `"user_default"`, `"mailbox:<uuid>"` or `"identity:<uuid>"`,
      only if the draft's `:from_editable`. The sender is worked out again
      from it: the mailbox must be one the person reaches, the identity one
      they may use from that mailbox (`Identities.list_usable/1`, then
      `Identities.resolve/3`) — `{:error, {:identity_unusable, reason}}`
      otherwise
    * `"to"`, `"cc"`, `"bcc"` — a list (or an index map, as forms send it) of
      recipients: `%{"address" => …, "route" => "internal" | "email",
      "label" => …}`, `%{"user" => uuid, "route" => …}` or just the text
      typed (route `:email`). Replace the draft's when present
    * `"subject"`, `"body"`
    * `"reply_to"` — one of the person's `Identities.reply_to_options/2` or
      the draft's `:reply_to_trusted`; `""` for none
    * `"attachments"` — the ids of the draft's attachments that stay (all when
      absent); `"added_attachments"` — file uuids picked from the host's
      library, which must pass `authorize_attachments`

  Never read from the form: identity uuids, `links`, `html_body`, the
  conversation (`reply_to_message`), the idempotency key, a trusted Reply-To,
  attachment contents.

  ## Checks, each with a friendly error (an atom or tuple for `PhoenixKitInbox.Errors`)

    * a scope without `inbox` is `{:error, :forbidden}`; nothing runs
    * recipients: one address to an entry (no comma, semicolon or control
      character), duplicates within a field dropped, at most 20 To, 5 Cc, 5 Bcc
      (`{:too_many_recipients, role, max}`), at least one in all
    * subject at most 500 characters (`:subject_too_long`); text without NUL or
      invalid UTF-8 (`:invalid_text`); `html_body` at most 256 KiB
    * Reply-To (`:reply_to_not_allowed`)
    * attachments of the host only from the draft; picked ones through
      `authorize_attachments.(scope, context, uuids)` (`:ok` or `{:error, term}`),
      with `context` the draft's `:context` plus its `:links`; no callback,
      no pick
    * **route against resolve**, inside the `send_fun` handed to `around_send`
      (see below): a recipient chosen as `:internal` that resolves to an
      outside address is `{:error, {:route_mismatch, [%{address, route,
      resolved}]}}`; one typed as `:email` that resolves to a person or mailbox
      inside is `{:error, {:member_as_email, addresses}}` — "choose them from
      the list"

  ## `around_send`

  `callbacks.around_send` is `fn scope, draft, send_fun -> result end`
  (default: `send_fun.(draft)`), the host's wrapper around the send. It is
  called in the process that runs the pipeline and must call `send_fun` in it
  too: `send_fun.(draft')` resolves the recipients' routes **then**, in the
  process context the wrapper set up (a host that lists its clients in the
  process dictionary, say), and then sends. `draft'` may differ from the draft
  given in `:subject`, `:body`, `:html_body` and `:attachments` only; the
  recipients, sender, links, Reply-To, conversation and key are those
  checked here. The wrapper's answer is the pipeline's: `{:ok, message}` or
  `{:error, term}`; anything else is `{:error, :send_failed}`.

  Errors from the host's callbacks are not caught here.
  """

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Schemas.Message
  alias PhoenixKitInbox.Web.Components.ComposeDraft

  @max_per_role %{to: 20, cc: 5, bcc: 5}
  @roles [:to, :cc, :bcc]
  @subject_max 500
  @html_max 256 * 1024
  @address_max 320
  @label_max 200
  @picks_max 50
  @bad_address ~r/[\x00-\x1f\x7f,;]/u

  @type callbacks :: %{
          optional(:around_send) => (Scope.t(), ComposeDraft.t(), (ComposeDraft.t() -> term()) ->
                                       term()),
          optional(:authorize_attachments) => (Scope.t(), map(), [binary()] ->
                                                 :ok | {:error, term()})
        }

  @doc """
  Sends what a compose form submitted as the person behind `scope`; see the
  module doc. Returns what the send returns (`{:ok, message}`), or
  `{:error, reason}` — never raises for the form's params.
  """
  @spec run(Scope.t() | nil, term(), ComposeDraft.t(), callbacks() | keyword()) ::
          {:ok, Message.t()} | {:error, term()}
  def run(scope, form_params, draft, callbacks \\ %{})

  def run(%Scope{} = scope, form_params, %ComposeDraft{} = draft, callbacks) do
    if Scope.can?(scope, "inbox"),
      do: checked(scope, if(is_map(form_params), do: form_params, else: %{}), draft, callbacks),
      else: {:error, :forbidden}
  end

  def run(_scope, _form_params, _draft, _callbacks), do: {:error, :forbidden}

  defp checked(scope, params, %ComposeDraft{} = draft, callbacks) do
    callbacks = callbacks(callbacks)

    with {:ok, recipients} <- recipients(draft, params),
         {:ok, text} <- text(draft, params),
         {:ok, sender} <- sender(scope, draft, params, recipients),
         {:ok, reply_to} <- reply_to(scope, sender.mailbox, draft, params),
         {:ok, attachments} <- attachments(scope, draft, params, callbacks) do
      verified = %{recipients: recipients, sender: sender, reply_to: reply_to}

      draft = %ComposeDraft{
        draft
        | to: recipients.to,
          cc: recipients.cc,
          bcc: recipients.bcc,
          subject: text.subject,
          body: text.body,
          attachments: attachments,
          from: sender.choice,
          reply_to: reply_to && reply_to.address
      }

      scope
      |> callbacks.around_send.(draft, &send(scope, verified, draft, &1))
      |> answer()
    end
  end

  defp callbacks(callbacks) when is_list(callbacks), do: callbacks(Map.new(callbacks))

  defp callbacks(callbacks) when is_map(callbacks) do
    %{
      around_send:
        valid_fun(callbacks[:around_send], 3, fn _scope, draft, send_fun -> send_fun.(draft) end),
      authorize_attachments: valid_fun(callbacks[:authorize_attachments], 3, nil)
    }
  end

  defp callbacks(_), do: callbacks(%{})

  defp valid_fun(fun, arity, _default) when is_function(fun, arity), do: fun
  defp valid_fun(_fun, _arity, default), do: default

  defp answer({:ok, %Message{}} = ok), do: ok
  defp answer({:error, _reason} = error), do: error
  defp answer(_other), do: {:error, :send_failed}

  # ── recipients ──────────────────────────────────────────────────────────────

  defp recipients(draft, params) do
    Enum.reduce_while(@roles, {:ok, %{}}, fn role, {:ok, acc} ->
      source =
        case Map.fetch(params, Atom.to_string(role)) do
          {:ok, submitted} -> submitted
          :error -> Map.fetch!(draft, role)
        end

      case role_recipients(source, role) do
        {:ok, list} -> {:cont, {:ok, Map.put(acc, role, list)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, %{to: [], cc: [], bcc: []}} -> {:error, :no_recipients}
      other -> other
    end
  end

  defp role_recipients(source, role) do
    with {:ok, entries} <- entries(source),
         {:ok, list} <- parse_entries(entries) do
      list = Enum.uniq_by(list, &String.downcase(&1.address))
      max = Map.fetch!(@max_per_role, role)

      if length(list) > max,
        do: {:error, {:too_many_recipients, role, max}},
        else: {:ok, list}
    end
  end

  # A list, an index map ("0" => entry, as inputs_for forms send), a single
  # text, or nothing.
  defp entries(nil), do: {:ok, []}
  defp entries(list) when is_list(list), do: {:ok, list}
  defp entries(text) when is_binary(text), do: {:ok, [text]}

  defp entries(map) when is_map(map) and not is_struct(map) do
    if Enum.all?(Map.keys(map), &is_binary/1),
      do: {:ok, map |> Enum.sort_by(&index(elem(&1, 0))) |> Enum.map(&elem(&1, 1))},
      else: {:error, :invalid_recipients}
  end

  defp entries(_), do: {:error, :invalid_recipients}

  defp index(key) do
    case Integer.parse(key) do
      {n, ""} -> {0, n, key}
      _ -> {1, 0, key}
    end
  end

  defp parse_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case recipient(entry) do
        {:ok, recipient} -> {:cont, {:ok, [recipient | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  # Text typed by hand: an outside address until the person picks it from the
  # inside suggestions.
  defp recipient(text) when is_binary(text), do: recipient(%{address: text, route: :email})

  defp recipient(%{} = entry) when not is_struct(entry) do
    with {:ok, route} <- route(field(entry, :route)),
         {:ok, base} <- identity(entry, route) do
      {:ok, Map.merge(base, %{label: label(field(entry, :label)), route: route})}
    end
  end

  defp recipient(_), do: {:error, :invalid_recipients}

  defp route(nil), do: {:ok, :email}
  defp route(route) when route in [:internal, "internal"], do: {:ok, :internal}
  defp route(route) when route in [:email, "email"], do: {:ok, :email}
  defp route(_), do: {:error, :invalid_recipients}

  # A user wins over a text: the host knows them by account.
  defp identity(entry, route) do
    case {field(entry, :user), field(entry, :address)} do
      {user, _} when is_binary(user) ->
        case Mailboxes.recipient_address(user, route) do
          {:ok, address} -> {:ok, %{address: address, user: user}}
          {:error, _} -> {:error, {:invalid_recipient, user}}
        end

      {_, address} when is_binary(address) ->
        address = String.trim(address)

        if address_ok?(address),
          do: {:ok, %{address: address}},
          else: {:error, {:invalid_recipient, address}}

      _ ->
        {:error, :invalid_recipients}
    end
  end

  defp address_ok?(address) do
    address != "" and String.valid?(address) and String.length(address) <= @address_max and
      not Regex.match?(@bad_address, address)
  end

  defp label(label) when is_binary(label) do
    label = String.trim(label)
    if label != "" and String.valid?(label), do: String.slice(label, 0, @label_max), else: nil
  end

  defp label(_), do: nil

  # A key of a map that is the draft's (atoms) or the form's (strings).
  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  # ── text ────────────────────────────────────────────────────────────────────

  defp text(draft, params) do
    with {:ok, subject} <- text_field(params, "subject", draft.subject),
         {:ok, body} <- text_field(params, "body", draft.body),
         :ok <- subject_length(subject) do
      {:ok, %{subject: subject, body: body}}
    end
  end

  defp text_field(params, key, default) do
    value = Map.get(params, key, default)

    cond do
      value == nil -> {:ok, ""}
      storable?(value) -> {:ok, value}
      true -> {:error, :invalid_text}
    end
  end

  defp storable?(value),
    do: is_binary(value) and String.valid?(value) and not String.contains?(value, <<0>>)

  defp subject_length(subject) do
    if String.length(subject) > @subject_max, do: {:error, :subject_too_long}, else: :ok
  end

  # ── the sender ──────────────────────────────────────────────────────────────

  defp sender(scope, draft, params, recipients) do
    external? = Enum.any?(all(recipients), &(&1.route == :email))

    with {:ok, user_uuid} <- Mailboxes.scope_user_uuid(scope),
         {:ok, choice} <- from_choice(draft, params) do
      accessible = Mailboxes.list_accessible_mailboxes(user_uuid)
      resolve_sender(scope, choice, accessible, external?)
    else
      {:error, :forbidden} -> {:error, :forbidden}
      {:error, _} = error -> error
    end
  end

  defp all(recipients), do: recipients.to ++ recipients.cc ++ recipients.bcc

  defp from_choice(draft, params) do
    case {draft.from_editable, Map.get(params, "from")} do
      {true, from} when is_binary(from) and from != "" -> parse_from(from)
      {true, from} when not is_nil(from) and from != "" -> {:error, :invalid_from}
      _ -> valid_from(draft.from)
    end
  end

  defp parse_from("user_default"), do: {:ok, :user_default}
  defp parse_from("mailbox:" <> uuid), do: uuid_from(:mailbox, uuid)
  defp parse_from("identity:" <> uuid), do: uuid_from(:identity, uuid)
  defp parse_from(_), do: {:error, :invalid_from}

  defp valid_from(:user_default), do: {:ok, :user_default}

  defp valid_from({kind, uuid}) when kind in [:mailbox, :identity] and is_binary(uuid),
    do: uuid_from(kind, uuid)

  defp valid_from(_), do: {:error, :invalid_from}

  defp uuid_from(kind, uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> {:ok, {kind, uuid}}
      :error -> {:error, :invalid_from}
    end
  end

  defp resolve_sender(scope, :user_default, _accessible, external?) do
    with {:ok, mailbox} <- Mailboxes.ensure_user_mailbox(scope.user) do
      {:ok, sender(:user_default, mailbox, default_identity(scope, mailbox, external?))}
    end
  end

  defp resolve_sender(scope, {:mailbox, uuid}, accessible, external?) do
    case Enum.find(accessible, &(&1.uuid == uuid)) do
      nil ->
        {:error, :mailbox_access_denied}

      mailbox ->
        {:ok, sender({:mailbox, uuid}, mailbox, default_identity(scope, mailbox, external?))}
    end
  end

  defp resolve_sender(scope, {:identity, uuid}, accessible, _external?) do
    with {:ok, usable} <- usable_identity(scope, uuid),
         {:ok, mailbox} <- identity_mailbox(scope, usable, accessible),
         {:ok, _resolved} <- resolve_identity(scope, uuid, mailbox) do
      {:ok, sender({:identity, uuid}, mailbox, uuid)}
    end
  end

  defp sender(choice, mailbox, identity_uuid),
    do: %{choice: choice, mailbox: mailbox, identity_uuid: identity_uuid}

  # The first identity the person may send from this mailbox as, by label: the
  # module has no setting for a default of their own.
  defp default_identity(_scope, _mailbox, false), do: nil

  defp default_identity(scope, mailbox, true) do
    case Identities.list_usable(scope, mailbox) do
      [%{identity_uuid: uuid} | _] -> uuid
      [] -> nil
    end
  end

  defp usable_identity(scope, uuid) do
    case Enum.find(Identities.list_usable(scope), &(&1.identity_uuid == uuid)) do
      nil -> {:error, {:identity_unusable, :not_found}}
      identity -> {:ok, identity}
    end
  end

  defp identity_mailbox(scope, %{mailbox_uuid: nil}, _accessible),
    do: Mailboxes.ensure_user_mailbox(scope.user)

  defp identity_mailbox(_scope, %{mailbox_uuid: uuid}, accessible) do
    case Enum.find(accessible, &(&1.uuid == uuid)) do
      nil -> {:error, :mailbox_access_denied}
      mailbox -> {:ok, mailbox}
    end
  end

  defp resolve_identity(scope, uuid, mailbox) do
    case Identities.resolve(scope, uuid, mailbox) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, {:identity_unusable, reason}}
    end
  end

  # ── Reply-To ────────────────────────────────────────────────────────────────

  # Absent from the form: the draft's. Present and blank: none. Otherwise it
  # must be one of the person's options or the host's trusted address.
  defp reply_to(scope, mailbox, draft, params) do
    trusted = trusted(draft.reply_to_trusted)
    wanted = Map.fetch(params, "reply_to")

    case wanted do
      :error -> pick(scope, mailbox, trusted, trusted || draft.reply_to)
      {:ok, nil} -> {:ok, nil}
      {:ok, ""} -> {:ok, nil}
      {:ok, address} when is_binary(address) -> pick(scope, mailbox, trusted, address)
      {:ok, _} -> {:error, :reply_to_not_allowed}
    end
  end

  defp trusted(address) when is_binary(address) do
    case String.trim(address) do
      "" -> nil
      address -> address
    end
  end

  defp trusted(_), do: nil

  defp pick(_scope, _mailbox, _trusted, nil), do: {:ok, nil}

  defp pick(scope, mailbox, trusted, address) do
    case Identities.allowed_reply_to(scope, mailbox, address) do
      {:ok, allowed} ->
        {:ok, %{address: allowed, trusted?: false}}

      {:error, :reply_to_not_allowed} ->
        if trusted && String.downcase(String.trim(address)) == String.downcase(trusted),
          do: {:ok, %{address: trusted, trusted?: true}},
          else: {:error, :reply_to_not_allowed}
    end
  end

  # ── attachments ─────────────────────────────────────────────────────────────

  defp attachments(scope, draft, params, callbacks) do
    with {:ok, hosted} <- normalize_attachments(draft.attachments),
         {:ok, kept} <- keep(hosted, params),
         {:ok, picked} <- picked(scope, draft, params, kept, callbacks) do
      {:ok, kept ++ picked}
    end
  end

  defp keep(hosted, params) do
    case Map.fetch(params, "attachments") do
      :error -> {:ok, hosted}
      {:ok, nil} -> {:ok, hosted}
      {:ok, ids} when is_list(ids) -> {:ok, Enum.filter(hosted, &(&1.id in ids))}
      {:ok, _} -> {:error, :invalid_attachments}
    end
  end

  defp picked(scope, draft, params, kept, callbacks) do
    with {:ok, uuids} <- picked_uuids(Map.get(params, "added_attachments")) do
      held = for %{file_uuid: uuid} when is_binary(uuid) <- kept, do: uuid

      case uuids -- held do
        [] -> {:ok, []}
        new -> authorize(scope, draft, new, callbacks)
      end
    end
  end

  defp picked_uuids(nil), do: {:ok, []}

  defp picked_uuids(list) when is_list(list) and length(list) <= @picks_max do
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
      with true <- is_binary(value), {:ok, uuid} <- Ecto.UUID.cast(value) do
        {:cont, {:ok, [uuid | acc]}}
      else
        _ -> {:halt, {:error, :invalid_attachments}}
      end
    end)
    |> case do
      {:ok, uuids} -> {:ok, uuids |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp picked_uuids(_), do: {:error, :invalid_attachments}

  defp authorize(scope, draft, uuids, %{authorize_attachments: fun}) when is_function(fun, 3) do
    context = Map.put(draft.context || %{}, :links, draft.links)

    case fun.(scope, context, uuids) do
      :ok -> {:ok, Enum.map(uuids, &%{id: &1, file_uuid: &1, name: nil, flags: nil})}
      {:error, _} = error -> error
      _ -> {:error, {:attachment_forbidden, hd(uuids)}}
    end
  end

  defp authorize(_scope, _draft, uuids, _callbacks),
    do: {:error, {:attachment_forbidden, hd(uuids)}}

  defp normalize_attachments(list) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
      case attachment(entry, index) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        :error -> {:halt, {:error, :invalid_attachments}}
      end
    end)
    |> case do
      {:ok, items} -> unique_ids(Enum.reverse(items))
      error -> error
    end
  end

  defp normalize_attachments(nil), do: {:ok, []}
  defp normalize_attachments(_), do: {:error, :invalid_attachments}

  defp attachment(%{} = entry, index) when not is_struct(entry) do
    flags = field(entry, :flags)
    flags = if is_map(flags), do: flags

    case {source(entry), field(entry, :filename)} do
      {{:file, uuid}, _} ->
        {:ok,
         %{id: id(entry, uuid, index), file_uuid: uuid, name: field(entry, :name), flags: flags}}

      {{:data, source}, filename} when is_binary(filename) and filename != "" ->
        {:ok,
         Map.merge(source, %{
           id: id(entry, "data-#{index}", index),
           name: field(entry, :name) || filename,
           filename: filename,
           content_type: field(entry, :content_type),
           flags: flags
         })}

      _ ->
        :error
    end
  end

  defp attachment(_, _), do: :error

  defp source(entry) do
    case {field(entry, :file_uuid), field(entry, :binary), field(entry, :path)} do
      {uuid, _, _} when is_binary(uuid) ->
        case Ecto.UUID.cast(uuid) do
          {:ok, uuid} -> {:file, uuid}
          :error -> :error
        end

      {_, binary, _} when is_binary(binary) ->
        {:data, %{binary: binary}}

      {_, _, path} when is_binary(path) ->
        {:data, %{path: path}}

      _ ->
        :error
    end
  end

  defp id(entry, default, _index) do
    case field(entry, :id) do
      id when is_binary(id) and id != "" -> id
      _ -> default
    end
  end

  defp unique_ids(items) do
    if length(Enum.uniq_by(items, & &1.id)) == length(items),
      do: {:ok, items},
      else: {:error, :invalid_attachments}
  end

  # What `send_message/4` takes for them: files the host vouched for, their
  # flags, and bytes the host made.
  defp attachment_opts(items) do
    files = for %{file_uuid: uuid} <- items, do: uuid
    flags = for %{file_uuid: uuid, flags: %{} = flags} <- items, into: %{}, do: {uuid, flags}

    data =
      for %{filename: _} = item <- items do
        item
        |> Map.take([:binary, :path, :filename, :content_type, :flags])
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
      end

    [attachments_authorized: files, attachment_flags: flags, attachments_data: data]
    |> Enum.reject(fn {_key, value} -> value in [[], %{}] end)
  end

  # ── the send ────────────────────────────────────────────────────────────────

  # Handed to the host's wrapper. Runs in the wrapper's process and context:
  # the routes are checked here, then the message goes.
  defp send(scope, verified, given, final) do
    with {:ok, final} <- final_draft(final, given),
         {:ok, text} <- text(final, %{}),
         {:ok, html} <- html_body(final.html_body),
         {:ok, items} <- normalize_attachments(final.attachments),
         :ok <- check_routes(scope, all(verified.recipients)) do
      attrs = attrs(verified, given, text)
      opts = opts(verified, given, html, items)
      Messages.send_message(scope, verified.sender.mailbox, attrs, opts)
    end
  end

  # Of what the wrapper hands back, only the four fields it may change count.
  defp final_draft(%ComposeDraft{} = final, %ComposeDraft{} = given) do
    {:ok,
     %ComposeDraft{
       given
       | subject: final.subject,
         body: final.body,
         html_body: final.html_body,
         attachments: final.attachments
     }}
  end

  defp final_draft(_, _), do: {:error, :send_failed}

  defp html_body(nil), do: {:ok, nil}

  defp html_body(html) when is_binary(html) do
    cond do
      byte_size(html) > @html_max -> {:error, :html_body_too_large}
      not String.valid?(html) or String.contains?(html, <<0>>) -> {:error, :invalid_html_body}
      true -> {:ok, html}
    end
  end

  defp html_body(_), do: {:error, :invalid_html_body}

  defp check_routes(scope, recipients) do
    resolved = Messages.resolve_recipient_routes(scope, Enum.map(recipients, & &1.address))

    if length(resolved) == length(recipients) do
      recipients
      |> Enum.zip(resolved)
      |> Enum.filter(fn {chosen, found} -> chosen.route != found.route end)
      |> refuse_differing()
    else
      {:error, :route_check_failed}
    end
  end

  # A person's typed e-mail that is someone inside is theirs to fix (pick them
  # from the list); any other disagreement is the host's route against the
  # process it runs in.
  defp refuse_differing([]), do: :ok

  defp refuse_differing(differing) do
    case for({%{route: :email} = chosen, %{route: :internal}} <- differing, do: chosen.address) do
      [] -> {:error, {:route_mismatch, mismatches(differing)}}
      members -> {:error, {:member_as_email, members}}
    end
  end

  defp mismatches(differing),
    do:
      for(
        {chosen, found} <- differing,
        do: %{address: chosen.address, route: chosen.route, resolved: found.route}
      )

  defp attrs(verified, given, text) do
    sender = verified.sender

    %{
      "to" => addresses(verified.recipients.to),
      "subject" => text.subject,
      "body" => text.body,
      "body_format" => body_format(given.body_format)
    }
    |> put_list("cc", verified.recipients.cc)
    |> put_list("bcc", verified.recipients.bcc)
    |> put_present("identity_uuid", sender.identity_uuid)
    |> put_present("parent_uuid", cast_uuid(given.reply_to_message))
    |> put_present("reply_to", allowed_reply_to(verified.reply_to))
  end

  defp opts(verified, given, html, items) do
    [
      links: if(is_list(given.links), do: given.links, else: []),
      html_body: html,
      reply_to_trusted: trusted_reply_to(verified.reply_to),
      idempotency_key: key(given.idempotency_key)
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, []] end)
    |> Kernel.++(attachment_opts(items))
  end

  defp addresses(list), do: Enum.map(list, & &1.address)
  defp put_list(attrs, _key, []), do: attrs
  defp put_list(attrs, key, list), do: Map.put(attrs, key, addresses(list))
  defp put_present(attrs, _key, nil), do: attrs
  defp put_present(attrs, key, value), do: Map.put(attrs, key, value)

  defp allowed_reply_to(%{address: address, trusted?: false}), do: address
  defp allowed_reply_to(_), do: nil
  defp trusted_reply_to(%{address: address, trusted?: true}), do: address
  defp trusted_reply_to(_), do: nil

  defp body_format(format) when format in ~w(text markdown html), do: format
  defp body_format(_), do: "markdown"

  defp cast_uuid(uuid) when is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp cast_uuid(_), do: nil

  defp key(key) when is_binary(key) and key != "", do: key
  defp key(_), do: nil
end
