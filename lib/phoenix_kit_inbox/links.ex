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

  Checks nothing about who asks: for server code only. A person's link goes
  through `link/5`.
  """
  @spec record(binary(), [link()], String.t(), keyword()) :: :ok
  def record(message_uuid, links, source, opts \\ [])
      when is_binary(message_uuid) and source in @sources do
    links = normalize(links)
    insert([message_uuid], links, source, Keyword.get(opts, :linked_by))
    Enum.each(links, &broadcast(&1, message_uuid))
  end

  @doc false
  # Stores the links the host gave a message (source "host"), for the send's
  # own transaction: the message and its host links are committed together or
  # not at all. Entries that are not a `kind`/`ref` pair within the limits are
  # dropped first (and counted in the log, without their content); a database
  # failure on valid ones is `{:error, :links_failed}` (logged), for the caller
  # to roll back. Announces nothing — the message is not committed yet. No
  # access check: server code only.
  @spec write_host(binary(), [link()]) :: :ok | {:error, :links_failed}
  def write_host(message_uuid, host_links) when is_binary(message_uuid) do
    host_links = List.wrap(host_links)
    links = normalize(host_links)

    case Enum.count(host_links, &(pair(&1) == [])) do
      0 -> :ok
      dropped -> Logger.warning("[Inbox] #{dropped} host link(s) dropped: malformed kind or ref")
    end

    insert([message_uuid], links, "host", nil)
  rescue
    e -> links_failed("host links", e, __STACKTRACE__)
  end

  @doc false
  # Writes into the send's own transaction what the earlier sent messages of
  # the conversation are linked to (source "thread"), so a reply never loses
  # an inherited link. Failure is `{:error, :links_failed}`, for the caller to
  # roll back. No access check: server code only.
  @spec write_thread(Message.t()) :: :ok | {:error, :links_failed}
  def write_thread(%Message{} = message) do
    insert([message.uuid], thread_links(message), "thread", nil)
  rescue
    e -> links_failed("thread links", e, __STACKTRACE__)
  end

  defp links_failed(what, e, stacktrace) do
    Logger.error(
      "[Inbox] #{what} failed, the send is rolled back:\n" <>
        Exception.format(:error, e, stacktrace)
    )

    {:error, :links_failed}
  end

  @doc false
  # Right after a message was committed: announces the links it was given in
  # the transaction (host and thread) to whoever watches those objects. Never
  # raises. No access check: server code only.
  @spec announce(Message.t()) :: :ok
  def announce(%Message{} = message) do
    guarded("link events", fn ->
      message.uuid
      |> for_message()
      |> Enum.each(&broadcast(&1, message.uuid))
    end)

    :ok
  end

  @doc false
  # After a message was committed, and last of all: writes the objects the
  # host's resolvers find in its subject ("subject" — see
  # `PhoenixKitInbox.LinkResolver`) and announces them. The resolvers are host
  # code, so this runs after everything else. Never raises and never fails the
  # send: a failure, a crashing resolver included, is logged and the rest goes
  # on. No access check: server code only.
  @spec apply_to_new_message(Message.t()) :: :ok
  def apply_to_new_message(%Message{} = message) do
    guarded("subject links", fn -> record(message.uuid, subject_links(message), "subject") end)
    :ok
  end

  # What the other sent messages of the conversation are linked to.
  defp thread_links(%Message{thread_uuid: thread_uuid} = message) when is_binary(thread_uuid) do
    from(l in Link,
      join: m in Message,
      on: m.uuid == l.message_uuid,
      where: m.thread_uuid == ^thread_uuid and m.uuid != ^message.uuid and m.status == "sent",
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
    e -> log_failure(what, "(#{inspect(e.__struct__)})")
  catch
    kind, reason -> log_failure(what, "(#{kind} of #{term_type(reason)})")
  end

  # Only what failed and the kind of the error: the message of an exception
  # (a FunctionClauseError, say) carries its arguments, which here are the
  # subject of a person's message.
  defp log_failure(what, kind) do
    Logger.error("[Inbox] #{what} failed #{kind}, the message is kept without them")
    :error
  end

  defp term_type(term) when is_atom(term), do: "an atom"
  defp term_type(term) when is_binary(term), do: "text"
  defp term_type(term) when is_tuple(term), do: "a tuple"
  defp term_type(term) when is_map(term), do: "a map"
  defp term_type(term) when is_list(term), do: "a list"
  defp term_type(_term), do: "another term"

  defp insert(_message_uuids, [], _source, _linked_by), do: :ok

  # One statement for every message and link; `source` wins a conflict only
  # when it is more explicit than the stored one.
  defp insert(message_uuids, links, source, linked_by) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      for message_uuid <- message_uuids, link <- links do
        %{
          message_uuid: message_uuid,
          kind: link.kind,
          ref: link.ref,
          source: source,
          linked_by_user_uuid: linked_by,
          inserted_at: now
        }
      end

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

  defp valid?(kind, ref), do: valid_text?(kind, @kind_max) and valid_text?(ref, @ref_max)

  @doc false
  # Whether `value` fits a `varchar(max)` column: a non-empty, valid UTF-8
  # binary without a NUL byte (Postgres refuses one), at most `max` code
  # points long (Postgres counts code points, not graphemes).
  @spec valid_text?(term(), pos_integer()) :: boolean()
  def valid_text?(value, max) when is_binary(value) do
    value != "" and String.valid?(value) and not String.contains?(value, <<0>>) and
      length(String.to_charlist(value)) <= max
  end

  def valid_text?(_value, _max), do: false

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

      insert(uuids, [%{kind: kind, ref: ref}], "manual", user_uuid)
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
      host_allows?(can_link?, scope, kind, ref) -> :ok
      true -> {:error, :forbidden}
    end
  end

  # The host's answer, and only a plain `true` is a yes. A callback that is no
  # fun of three, raises, throws or exits is a no: a click on a page must not
  # crash it. The log names the kind of failure, not the object or the person.
  defp host_allows?(can_link?, scope, kind, ref) when is_function(can_link?, 3) do
    can_link?.(scope, kind, ref) == true
  rescue
    e ->
      Logger.warning("[Inbox] can_link? raised #{inspect(e.__struct__)}; link refused")
      false
  catch
    failure, _reason ->
      Logger.warning("[Inbox] can_link? ended with a #{failure}; link refused")
      false
  end

  defp host_allows?(_can_link?, _scope, _kind, _ref) do
    Logger.warning("[Inbox] can_link? is not a function of three; link refused")
    false
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

  @doc """
  The links of a message, oldest first. Checks nothing about who asks: for
  server code only.
  """
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

  @doc "Undoes `subscribe/2` for the caller."
  @spec unsubscribe(String.t(), String.t()) :: :ok | {:error, term()}
  def unsubscribe(kind, ref) when is_binary(kind) and is_binary(ref),
    do: PubSub.unsubscribe(topic(kind, ref))

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
