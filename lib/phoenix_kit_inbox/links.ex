defmodule PhoenixKitInbox.Links do
  @moduledoc """
  Links from messages to objects of the host application.

  An object is named by a `kind` (at most 64 characters) and a `ref` (at most
  255) the module neither knows nor checks — `"order"` and the order's uuid,
  say. A message may be linked to any number of objects, and an object has the
  messages linked to it. Each link remembers where it came from (`source`):

    * `"host"` — the host gave it with the `links:` option of
      `PhoenixKitInbox.Messages.send_message/4` (never read from a form's
      attributes)
    * `"manual"` — a person linked it (`link/5`)
    * `"thread"` — inherited from the earlier messages of the conversation
    * `"subject"` — found in the subject by a `PhoenixKitInbox.LinkResolver`

  When two sources name the same object for the same message, one row is kept
  and the more explicit source wins: `host` over `manual` over `thread` over
  `subject`. A weaker source never overwrites a stronger one.

  A link does not widen who may read a message: reading stays a matter of the
  mailboxes a person can reach.

  ## Events

  Whoever cares about an object subscribes to it (`subscribe/2`) and gets
  `{:inbox_message_linked, message_uuid}` whenever a message is linked to it
  or unlinked from it. The event says only that something changed; the
  receiver checks what it may see itself.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.PubSub.Manager, as: PubSub
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Schemas.Link
  alias PhoenixKitInbox.Schemas.Message

  @sources Link.sources()
  @kind_max 64
  @ref_max 255

  @type link :: %{kind: String.t(), ref: String.t()}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # How explicit a source is; the higher one survives a conflict.
  defmacrop rank(source) do
    quote do
      fragment(
        "CASE ? WHEN 'host' THEN 4 WHEN 'manual' THEN 3 WHEN 'thread' THEN 2 ELSE 1 END",
        unquote(source)
      )
    end
  end

  # ── writing ─────────────────────────────────────────────────────────────────

  @doc """
  Links `message_uuid` to each of `links` (`%{kind: kind, ref: ref}`) as
  `source`, and tells the subscribers of those objects.

  A message already linked to an object keeps one row: its source changes
  only when `source` is more explicit than the stored one (see the module
  doc). Entries that are not a `kind`/`ref` pair of binaries within the
  limits are skipped. `linked_by:` (a user uuid) is stored with the link.
  """
  @spec record(binary(), [link()], String.t(), keyword()) :: :ok
  def record(message_uuid, links, source, opts \\ [])
      when is_binary(message_uuid) and source in @sources do
    links = normalize(links)
    insert(message_uuid, links, source, Keyword.get(opts, :linked_by))
    Enum.each(links, &broadcast(&1, message_uuid))
  end

  @doc """
  Writes the links of a message that was just sent: the `host_links` the host
  gave (source `"host"`), the links of the other messages of its conversation
  (`"thread"`), and the objects the host's resolvers find in its subject
  (`"subject"` — see `PhoenixKitInbox.LinkResolver`).

  Never raises and never fails the send: a failure in any of the three steps,
  a crashing resolver included, is logged and the rest goes on.
  """
  @spec apply_to_new_message(Message.t(), [link()]) :: :ok
  def apply_to_new_message(%Message{} = message, host_links) do
    guarded("host links", fn -> record(message.uuid, host_links, "host") end)
    guarded("thread links", fn -> record(message.uuid, thread_links(message), "thread") end)
    guarded("subject links", fn -> record(message.uuid, subject_links(message), "subject") end)
    :ok
  end

  # What the other messages of the conversation are linked to.
  defp thread_links(%Message{thread_uuid: thread_uuid} = message) when is_binary(thread_uuid) do
    from(l in Link,
      join: m in Message,
      on: m.uuid == l.message_uuid,
      where: m.thread_uuid == ^thread_uuid and m.uuid != ^message.uuid,
      distinct: true,
      select: %{kind: l.kind, ref: l.ref}
    )
    |> repo().all()
  end

  defp thread_links(_message), do: []

  defp subject_links(%Message{subject: subject}) when is_binary(subject) and subject != "" do
    Enum.flat_map(resolvers(), &resolve(&1, subject))
  end

  defp subject_links(_message), do: []

  defp resolvers,
    do: :phoenix_kit_inbox |> Application.get_env(:link_resolvers, []) |> List.wrap()

  # One resolver's links; any failure of it yields none.
  defp resolve(resolver, subject) do
    guarded("resolver #{inspect(resolver)}", fn ->
      kind = resolver.kind()

      subject
      |> resolver.extract()
      |> List.wrap()
      |> Enum.filter(&(is_binary(&1) and resolver.exists?(&1)))
      |> Enum.map(&%{kind: kind, ref: &1})
    end)
    |> case do
      links when is_list(links) -> links
      _failed -> []
    end
  end

  # Runs `fun`; a raise, throw or exit is logged and answered with `:error`.
  defp guarded(what, fun) do
    fun.()
  rescue
    e -> log_failure(what, Exception.format(:error, e, __STACKTRACE__))
  catch
    kind, reason -> log_failure(what, Exception.format(kind, reason, __STACKTRACE__))
  end

  defp log_failure(what, formatted) do
    Logger.error("[Inbox] #{what} failed, the message is kept without them:\n#{formatted}")
    :error
  end

  defp insert(_message_uuid, [], _source, _linked_by), do: :ok

  defp insert(message_uuid, links, source, linked_by) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      Enum.map(
        links,
        &%{
          message_uuid: message_uuid,
          kind: &1.kind,
          ref: &1.ref,
          source: source,
          linked_by_user_uuid: linked_by,
          inserted_at: now
        }
      )

    stronger =
      from(l in Link,
        where: rank(type(^source, :string)) > rank(l.source),
        update: [set: [source: ^source, linked_by_user_uuid: ^linked_by]]
      )

    repo().insert_all(Link, rows,
      on_conflict: stronger,
      conflict_target: [:message_uuid, :kind, :ref]
    )

    :ok
  end

  defp normalize(links) do
    links
    |> List.wrap()
    |> Enum.flat_map(&pair/1)
    |> Enum.uniq()
  end

  defp pair(%{kind: kind, ref: ref}), do: pair(kind, ref)
  defp pair(%{"kind" => kind, "ref" => ref}), do: pair(kind, ref)
  defp pair(_), do: []

  defp pair(kind, ref) do
    if valid?(kind, ref), do: [%{kind: kind, ref: ref}], else: []
  end

  defp valid?(kind, ref) do
    is_binary(kind) and is_binary(ref) and String.valid?(kind) and String.valid?(ref) and
      kind != "" and ref != "" and String.length(kind) <= @kind_max and
      String.length(ref) <= @ref_max
  end

  # ── by a person ─────────────────────────────────────────────────────────────

  @doc """
  Links a message to an object on behalf of the person behind `scope`.

  The message must be one `scope` can read (`Messages.fetch_for_scope/2`),
  otherwise `{:error, :message_not_found}`; the host must allow it: `opts`
  takes `can_link?: fn scope, kind, ref -> boolean end`, and without it the
  answer is `{:error, :forbidden}`. A malformed `kind` or `ref` is
  `{:error, :invalid_link}`.

  The link (source `"manual"`, `linked_by_user_uuid` the person) goes onto the
  message and onto every message of its conversation that exists now, so
  linking the root brings the whole conversation along; messages that come
  later inherit it. Returns the message's own row, which keeps a stronger
  source if it already had one.
  """
  @spec link(Scope.t(), binary(), String.t(), String.t(), keyword()) ::
          {:ok, Link.t()} | {:error, :forbidden | :message_not_found | :invalid_link}
  def link(%Scope{} = scope, message_uuid, kind, ref, opts \\ []) do
    with {:ok, %{message: message}} <- Messages.fetch_for_scope(scope, message_uuid),
         :ok <- allowed(scope, kind, ref, opts),
         {:ok, user_uuid} <- Mailboxes.scope_user_uuid(scope) do
      uuids = thread_message_uuids(message)

      {:ok, :ok} =
        repo().transaction(fn ->
          Enum.each(uuids, &insert(&1, [%{kind: kind, ref: ref}], "manual", user_uuid))
        end)

      Enum.each(uuids, &broadcast(%{kind: kind, ref: ref}, &1))
      {:ok, repo().get_by!(Link, message_uuid: message.uuid, kind: kind, ref: ref)}
    end
  end

  @doc """
  Takes the link to an object off one message, with the same checks as
  `link/5`. The other messages of its conversation keep theirs. Unlinking
  what is not linked is not an error.
  """
  @spec unlink(Scope.t(), binary(), String.t(), String.t(), keyword()) ::
          :ok | {:error, :forbidden | :message_not_found | :invalid_link}
  def unlink(%Scope{} = scope, message_uuid, kind, ref, opts \\ []) do
    with {:ok, %{message: message}} <- Messages.fetch_for_scope(scope, message_uuid),
         :ok <- allowed(scope, kind, ref, opts) do
      from(l in Link,
        where: l.message_uuid == ^message.uuid and l.kind == ^kind and l.ref == ^ref
      )
      |> repo().delete_all()

      broadcast(%{kind: kind, ref: ref}, message.uuid)
    end
  end

  defp allowed(scope, kind, ref, opts) do
    can_link? = Keyword.get(opts, :can_link?, fn _scope, _kind, _ref -> false end)

    cond do
      not valid?(kind, ref) -> {:error, :invalid_link}
      can_link?.(scope, kind, ref) == true -> :ok
      true -> {:error, :forbidden}
    end
  end

  # The message and the sent messages of its conversation.
  defp thread_message_uuids(%Message{uuid: uuid, thread_uuid: thread_uuid}) do
    others =
      from(m in Message,
        where: m.thread_uuid == ^thread_uuid and m.status == "sent",
        select: m.uuid
      )
      |> repo().all()

    Enum.uniq([uuid | others])
  end

  # ── reading ─────────────────────────────────────────────────────────────────

  @doc "The links of a message, oldest first."
  @spec for_message(binary()) :: [Link.t()]
  def for_message(message_uuid) when is_binary(message_uuid) do
    case Ecto.UUID.cast(message_uuid) do
      {:ok, uuid} ->
        from(l in Link,
          where: l.message_uuid == ^uuid,
          order_by: [asc: l.inserted_at, asc: l.uuid]
        )
        |> repo().all()

      :error ->
        []
    end
  end

  # ── events ──────────────────────────────────────────────────────────────────

  @doc """
  Subscribes the caller to the object `kind`/`ref`: it gets
  `{:inbox_message_linked, message_uuid}` when a message is linked to it or
  unlinked from it.
  """
  @spec subscribe(String.t(), String.t()) :: :ok | {:error, term()}
  def subscribe(kind, ref) when is_binary(kind) and is_binary(ref),
    do: PubSub.subscribe(topic(kind, ref))

  # The ref is the host's, so it is encoded: any character is safe in a topic.
  defp topic(kind, ref),
    do: "inbox:object:" <> kind <> ":" <> Base.url_encode64(ref, padding: false)

  defp broadcast(%{kind: kind, ref: ref}, message_uuid) do
    PubSub.broadcast(topic(kind, ref), {:inbox_message_linked, to_string(message_uuid)})
    :ok
  rescue
    e ->
      Logger.warning("[Inbox] link broadcast failed: #{Exception.message(e)}")
      :ok
  end
end
