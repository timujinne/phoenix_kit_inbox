defmodule PhoenixKitInbox.ObjectMail do
  @moduledoc """
  The mail of an object of the host application, as one person may read it.

  An object is named by a `kind` and a `ref` (see `PhoenixKitInbox.Links`);
  this module answers "which conversations are about it" for a given viewer.
  The answer is built **only** from the mailboxes the viewer can open
  (`Mailboxes.list_accessible_mailboxes/1`: their own and the shared ones they
  hold a grant on) — never from the conversation as a whole, so a link can
  point a letter at an object but cannot make it readable by anyone new. Other
  people's personal mailboxes do not come back for any filter.

  What is read:

    * a letter the viewer's mailboxes hold an active copy of in the Inbox or
      Sent folder, or sent from one of them and not moved out — the trash, the
      spam and the archive folders and drafts are not mail of the object;
    * a letter held through two of the viewer's mailboxes is one letter;
    * each letter as `Messages.project_for_viewer/2` shows it to the mailbox
      it is read through (the sending mailbox if the viewer holds a copy
      there, otherwise the first of the viewer's mailboxes holding a copy): another recipient's
      Bcc, the sending identity of someone else's letter and the host's
      `html_body` are not in it. The external recipients are filtered by the
      same rule.

  Needs `Scope.can?(scope, "inbox")`; without it every answer is `[]`.

  Reading costs a fixed number of queries whatever the number of mailboxes,
  conversations and letters.
  """

  import Ecto.Query

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitInbox.Links
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Schemas.Delivery
  alias PhoenixKitInbox.Schemas.ExternalRecipient
  alias PhoenixKitInbox.Schemas.Link
  alias PhoenixKitInbox.Schemas.Message

  @folders ~w(inbox sent)
  @kind_max 64
  @ref_max 255
  @default_limit 50
  @max_limit 200

  @typedoc ~S|An object of the host: `%{kind: "order", ref: "123"}`.|
  @type object :: %{kind: String.t(), ref: String.t()}

  @typedoc """
  One letter as the viewer reads it:

    * `:message` — the letter, projected for `:viewer_mailbox_uuid`
    * `:direction` — `:sent` if one of the viewer's mailboxes sent it,
      otherwise `:inbox`
    * `:depth` — how deep it is in the conversation tree (0 for a root, and
      for a reply whose parent the viewer cannot read)
    * `:links` — its links to the objects asked for (`Links` rows)
    * `:external` — its external recipients the viewer may see
  """
  @type entry :: %{
          message: Message.t(),
          viewer_mailbox_uuid: binary(),
          direction: :inbox | :sent,
          depth: non_neg_integer(),
          links: [Link.t()],
          external: [ExternalRecipient.t()]
        }

  @type thread :: %{thread_uuid: binary(), last_at: DateTime.t() | nil, messages: [entry()]}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc """
  The conversations `scope` can read that have a letter linked to any object
  of `filter` (a list of `%{kind: ..., ref: ...}`), newest first.

  A conversation is listed when **any** letter the viewer can read is linked
  to the filter, and then carries **all** the letters of it the viewer can
  read, parents before replies (see `t:entry/0`). `last_at` is the time of the
  newest of them.

  `opts`:

    * `:folder` — `:all` (default), `:inbox` or `:sent`: only the
      conversations with at least one letter the viewer received, or sent
    * `:limit` (default #{@default_limit}, at most #{@max_limit}) and `:offset`
      — count conversations, not letters
  """
  @spec list_threads(Scope.t() | nil, [object()], keyword()) :: [thread()]
  def list_threads(scope, filter, opts \\ []) do
    with {:ok, mailbox_uuids} <- viewer_mailboxes(scope),
         [_ | _] = objects <- normalize_filter(filter) do
      mailbox_uuids
      |> thread_page(objects, opts)
      |> case do
        [] -> []
        page -> assemble(page, mailbox_uuids, objects)
      end
    else
      _ -> []
    end
  end

  @doc """
  The letters `scope` can read that are linked to no object at all — what a
  person may pick from to link one by hand — newest first, as `t:entry/0`s
  (`:links` is `[]`). `opts`: `:limit` (default #{@default_limit}, at most
  #{@max_limit}).
  """
  @spec link_candidates(Scope.t() | nil, keyword()) :: [entry()]
  def link_candidates(scope, opts \\ []) do
    case viewer_mailboxes(scope) do
      {:ok, mailbox_uuids} ->
        unlinked = from(l in Link, where: l.message_uuid == parent_as(:message).uuid)

        from(m in visible(mailbox_uuids),
          where: not exists(unlinked),
          order_by: [desc: m.sent_at, desc: m.uuid],
          limit: ^limit(opts)
        )
        |> repo().all()
        |> entries(mailbox_uuids, [])

      :none ->
        []
    end
  end

  # ── who is reading ──────────────────────────────────────────────────────────

  defp viewer_mailboxes(%Scope{} = scope) do
    with true <- Scope.can?(scope, "inbox"),
         {:ok, user_uuid} <- Mailboxes.scope_user_uuid(scope),
         [_ | _] = mailboxes <- Mailboxes.list_accessible_mailboxes(user_uuid) do
      {:ok, Enum.map(mailboxes, & &1.uuid)}
    else
      _ -> :none
    end
  end

  defp viewer_mailboxes(_), do: :none

  @doc """
  A filter as the module reads it: the valid objects (atom or string keys,
  text within the limits of `PhoenixKitInbox.Links`), each once, sorted — so
  two filters naming the same objects in another order compare equal.
  Anything else in the list is dropped; a filter that is not a list is `[]`.
  """
  @spec normalize_filter(term()) :: [object()]
  def normalize_filter(filter) when is_list(filter) do
    filter
    |> Enum.flat_map(fn
      %{kind: kind, ref: ref} -> object(kind, ref)
      %{"kind" => kind, "ref" => ref} -> object(kind, ref)
      _ -> []
    end)
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.kind, &1.ref})
  end

  def normalize_filter(_), do: []

  defp object(kind, ref) do
    if Links.valid_text?(kind, @kind_max) and Links.valid_text?(ref, @ref_max),
      do: [%{kind: kind, ref: ref}],
      else: []
  end

  defp limit(opts) do
    case Keyword.get(opts, :limit, @default_limit) do
      n when is_integer(n) and n > 0 -> min(n, @max_limit)
      _ -> @default_limit
    end
  end

  defp offset(opts) do
    case Keyword.get(opts, :offset, 0) do
      n when is_integer(n) and n > 0 -> n
      _ -> 0
    end
  end

  # ── what can be read ────────────────────────────────────────────────────────

  # Sent letters with an active Inbox or Sent copy in one of `mailbox_uuids`.
  # Named `:message`, for the subqueries built on it.
  defp visible(mailbox_uuids) do
    copy =
      from(d in Delivery,
        where: d.message_uuid == parent_as(:message).uuid,
        where: d.mailbox_uuid in ^mailbox_uuids,
        where: d.status == "active" and d.folder in ^@folders
      )

    from(m in Message, as: :message, where: m.status == "sent" and exists(copy))
  end

  # One page of conversations: those with a readable letter linked to the
  # filter (and, for a folder, a readable letter of that direction), newest
  # first.
  defp thread_page(mailbox_uuids, objects, opts) do
    matching =
      from(m in visible(mailbox_uuids),
        join: l in Link,
        as: :link,
        on: l.message_uuid == m.uuid,
        where: ^link_match(objects),
        select: m.thread_uuid
      )

    from(m in visible(mailbox_uuids),
      where: m.thread_uuid in subquery(matching),
      group_by: m.thread_uuid,
      having: ^folder_match(Keyword.get(opts, :folder, :all), mailbox_uuids),
      order_by: [desc: max(m.sent_at), desc: m.thread_uuid],
      limit: ^limit(opts),
      offset: ^offset(opts),
      select: {m.thread_uuid, max(m.sent_at)}
    )
    |> repo().all()
  end

  # (kind = a AND ref IN refs) OR (kind = b AND ...): one condition on the
  # (kind, ref) index.
  defp link_match(objects) do
    objects
    |> Enum.group_by(& &1.kind, & &1.ref)
    |> Enum.reduce(dynamic(false), fn {kind, refs}, acc ->
      dynamic([link: l], ^acc or (l.kind == ^kind and l.ref in ^refs))
    end)
  end

  # The direction of a letter is "one of the viewer's mailboxes sent it".
  defp folder_match(:inbox, mailbox_uuids),
    do:
      dynamic(
        [m],
        fragment("bool_or(NOT coalesce(?, false))", m.sender_mailbox_uuid in ^mailbox_uuids)
      )

  defp folder_match(:sent, mailbox_uuids),
    do:
      dynamic(
        [m],
        fragment("bool_or(coalesce(?, false))", m.sender_mailbox_uuid in ^mailbox_uuids)
      )

  defp folder_match(_all, _mailbox_uuids), do: dynamic(true)

  # ── building the answer ─────────────────────────────────────────────────────

  defp assemble(page, mailbox_uuids, objects) do
    thread_uuids = Enum.map(page, &elem(&1, 0))

    by_thread =
      from(m in visible(mailbox_uuids), where: m.thread_uuid in ^thread_uuids)
      |> repo().all()
      |> entries(mailbox_uuids, objects)
      |> Enum.group_by(& &1.message.thread_uuid)

    Enum.map(page, fn {thread_uuid, last_at} ->
      %{
        thread_uuid: thread_uuid,
        last_at: last_at,
        messages: by_thread |> Map.get(thread_uuid, []) |> tree()
      }
    end)
  end

  # Entries for `messages` (already known to be readable): the mailbox each is
  # read through, its projection, its links to `objects` and its external
  # recipients, each fetched for all of them in one query.
  defp entries([], _mailbox_uuids, _objects), do: []

  defp entries(messages, mailbox_uuids, objects) do
    uuids = Enum.map(messages, & &1.uuid)
    copies = copies(uuids, mailbox_uuids)
    links = links(uuids, objects)
    external = external(uuids)

    Enum.map(messages, fn message ->
      viewer = viewer_mailbox(message, Map.get(copies, message.uuid, []), mailbox_uuids)
      projected = Messages.project_for_viewer(message, viewer)

      %{
        message: projected,
        viewer_mailbox_uuid: viewer,
        direction: if(message.sender_mailbox_uuid in mailbox_uuids, do: :sent, else: :inbox),
        depth: 0,
        links: Map.get(links, message.uuid, []),
        external: external |> Map.get(message.uuid, []) |> visible_externals(message, viewer)
      }
    end)
  end

  # message uuid => the viewer's mailboxes holding an active copy of it.
  defp copies(uuids, mailbox_uuids) do
    from(d in Delivery,
      where: d.message_uuid in ^uuids and d.mailbox_uuid in ^mailbox_uuids,
      where: d.status == "active" and d.folder in ^@folders,
      select: {d.message_uuid, d.mailbox_uuid}
    )
    |> repo().all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # The sending mailbox when the viewer holds a copy of the letter there (they
  # see the whole letter, as the Inbox shows that mailbox); otherwise the first
  # of their mailboxes (personal first) holding a copy. Being allowed into the
  # sending mailbox is not enough: a viewer who reads the letter only through
  # their own copy reads what a recipient reads.
  defp viewer_mailbox(message, copies, mailbox_uuids) do
    if message.sender_mailbox_uuid in copies do
      message.sender_mailbox_uuid
    else
      Enum.find(mailbox_uuids, &(&1 in copies))
    end
  end

  defp links(_uuids, []), do: %{}

  defp links(uuids, objects) do
    from(l in Link,
      as: :link,
      where: l.message_uuid in ^uuids,
      where: ^link_match(objects),
      order_by: [asc: l.inserted_at, asc: l.uuid]
    )
    |> repo().all()
    |> Enum.group_by(& &1.message_uuid)
  end

  defp external(uuids) do
    from(r in ExternalRecipient,
      where: r.message_uuid in ^uuids,
      order_by: [
        asc: fragment("array_position(ARRAY['to','cc','bcc']::varchar[], ?)", r.role),
        asc: r.inserted_at,
        asc: r.uuid
      ]
    )
    |> repo().all()
    |> Enum.group_by(& &1.message_uuid)
  end

  # An external Bcc stays blind, like an internal one: only the sending
  # mailbox sees it (the rule of `External.list_for_viewer/2`).
  defp visible_externals(rows, message, viewer) do
    sender? = message.sender_mailbox_uuid == viewer
    Enum.filter(rows, &(sender? or &1.role != "bcc"))
  end

  # Parents before their replies, siblings in the order sent. A reply whose
  # parent is not among the entries is a root.
  defp tree(entries) do
    known = MapSet.new(entries, & &1.message.uuid)

    children =
      Enum.group_by(entries, fn %{message: m} ->
        if m.parent_uuid in known and m.parent_uuid != m.uuid, do: m.parent_uuid
      end)

    walk(Map.get(children, nil, []), children, 0)
  end

  defp walk(entries, children, depth) do
    entries
    |> Enum.sort_by(&{&1.message.sent_at, &1.message.uuid}, &sent_order/2)
    |> Enum.flat_map(fn entry ->
      [
        %{entry | depth: depth}
        | walk(Map.get(children, entry.message.uuid, []), children, depth + 1)
      ]
    end)
  end

  defp sent_order({at_a, uuid_a}, {at_b, uuid_b}) do
    case DateTime.compare(at_a || ~U[1970-01-01 00:00:00Z], at_b || ~U[1970-01-01 00:00:00Z]) do
      :lt -> true
      :gt -> false
      :eq -> uuid_a <= uuid_b
    end
  end
end
