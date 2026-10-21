defmodule PhoenixKitInbox.External do
  @moduledoc """
  The external part of a message: its recipients outside the application
  (`PhoenixKitInbox.Schemas.ExternalRecipient`), the email that goes to them,
  and its retry.

  ## Order of a send

  `Messages.send_message/4` writes the message, its deliveries and its
  external recipients (`"pending"`) in one transaction. After the commit
  the email is built and sent in a task under the module's
  `PhoenixKitInbox.TaskSupervisor`, so the sender's page never waits for
  SMTP; the rows become `"sent"` or `"failed"` and
  `{:inbox_external_updated, message_uuid}` is broadcast on the sending
  mailbox's topic (`subscribe/1`). A failure there never touches the
  internal part, which is already delivered.

  The sending identity is checked (`Identities.resolve/3`, with its
  integration and owner) and so is the right to write externally — by
  `send_message/4` before the transaction, and again in the task, just
  before the email is built, with the sender's scope; the email goes out as
  that second check returns (From name, integration). An identity or
  integration broken in between fails the rows, and nothing is sent. The
  right is checked against that same `%Scope{}`, whose permissions were
  read when the scope was built (`cached_permissions`): a `send_external`
  withdrawn after the send is not seen by the task, only by the next send
  or retry with a fresh scope. A retry checks the same way, for the user
  who retries, and the email log names them (`user_uuid`).

  The right itself (`allowed?/2`) is `inbox.send_external`, or a personal
  identity. Which common sender (shared, bound to no mailbox) a holder may
  go out as is narrowed further by its roles (`PhoenixKitInbox.Identities`):
  that check is part of `Identities.resolve/3`, so the task and a retry read
  the sender's roles anew — a role taken off after the commit stops the
  email — against the roles in effect in the same `%Scope{}`.

  A transport that raises, exits or throws is a failed send. An exit after
  the relay took the message would make that a false "failed" — the retry's
  email-log guard is what keeps such a message from going twice.

  All external recipients travel in **one** email — To, Cc and Bcc as
  addressed — sent through `PhoenixKitInbox.Outbound` from the message's
  sending identity (its From name and login address), with the message's
  Reply-To. The body is the Markdown body as `PhoenixKitInbox.Body`
  renders it (HTML) and as plain text; a text or HTML body goes as plain
  text. Attachments go as real attachments, read from Storage, up to
  `PhoenixKitInbox.external_max_bytes/0` in total as they travel (base64);
  a larger message is refused before anything is stored or sent.

  ## Status

  `display_status/2`: `:sent`, `:failed`, `:pending` — and `:unknown` for a
  row still pending after 15 minutes (the task died, or the server
  restarted mid-send): it may or may not have gone, and the email log tells.

  ## Retry

  `retry/3` re-sends the failed rows of a message, only:

    * from its sending mailbox, with the same rights as sending it;
    * when the host runs `phoenix_kit_emails` — without its log nobody can
      tell whether a failure really sent nothing — and every log row of the
      message's email says `failed` or `rejected` (any other status means
      the email went out);
    * never for a message the host recorded (`Messages.record_sent/4`).

  The guard is only as good as the log: with `phoenix_kit_emails` sampling
  below 100 %, or not logging this send, a failed message has no log rows
  and is offered for retry.

  Rows are taken from `"failed"` to `"pending"` in one statement, so two
  retries at once send one email. It goes through the same `Outbound` path.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Email.Markdown
  alias PhoenixKit.PubSub.Manager, as: PubSub
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitInbox.Attachments
  alias PhoenixKitInbox.Body
  alias PhoenixKitInbox.EmailLog
  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Outbound
  alias PhoenixKitInbox.Schemas.ExternalRecipient
  alias PhoenixKitInbox.Schemas.Mailbox
  alias PhoenixKitInbox.Schemas.Message

  @unknown_after_seconds 15 * 60
  @send_external "inbox.send_external"
  @failed_log_statuses ~w(failed rejected)
  @email ~r/\A[^\s@<>",;]+@[^\s@<>",;]+\.[^\s@<>",;]+\z/
  @max_error_length 500
  @max_address_bytes 254

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ── addresses ───────────────────────────────────────────────────────────────

  @doc """
  Whether `term` is an email address an external recipient can have — at
  most #{@max_address_bytes} bytes (RFC 5321's limit, and within the column).
  """
  @spec address?(term()) :: boolean()
  def address?(term) when is_binary(term) do
    address = String.trim(term)
    byte_size(address) <= @max_address_bytes and Regex.match?(@email, address)
  end

  def address?(_), do: false

  @doc """
  Whether the scope may write to external addresses, sending as the
  identity recorded for the message (`metadata["identity"]`): with
  `inbox.send_external`, or as their own personal identity.
  """
  @spec allowed?(Scope.t() | nil, map() | nil) :: boolean()
  def allowed?(%Scope{} = scope, identity) do
    Scope.can?(scope, @send_external) or match?(%{"kind" => "personal"}, identity)
  end

  def allowed?(_scope, _identity), do: false

  @doc """
  Refuses attachments too large for external mail: their total size as
  base64 (with line breaks) above `PhoenixKitInbox.external_max_bytes/0` is
  `{:error, {:external_too_large, max}}`. Takes byte sizes.
  """
  @spec check_size([non_neg_integer()]) :: :ok | {:error, {:external_too_large, pos_integer()}}
  def check_size(sizes) do
    max = PhoenixKitInbox.external_max_bytes()
    total = sizes |> Enum.map(&encoded_size/1) |> Enum.sum()

    if total > max, do: {:error, {:external_too_large, max}}, else: :ok
  end

  defp encoded_size(bytes) when is_integer(bytes) and bytes > 0 do
    base64 = div(bytes + 2, 3) * 4
    base64 + div(base64, 76) * 2
  end

  defp encoded_size(_), do: 0

  # ── rows ────────────────────────────────────────────────────────────────────

  @doc false
  # Inside the send transaction: one pending row per `%{role, address}`.
  @spec insert_pending(Ecto.Repo.t(), binary(), [map()]) ::
          {:ok, [ExternalRecipient.t()]} | {:error, term()}
  def insert_pending(repo, message_uuid, externals),
    do: insert_rows(repo, message_uuid, Enum.map(externals, &Map.put(&1, :status, "pending")))

  @doc false
  # Inside `Messages.record_sent/4`'s transaction: rows with the outcome the
  # host reports.
  @spec insert_rows(Ecto.Repo.t(), binary(), [map()]) ::
          {:ok, [ExternalRecipient.t()]} | {:error, term()}
  def insert_rows(repo, message_uuid, entries) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      row = %ExternalRecipient{
        message_uuid: message_uuid,
        role: entry.role,
        address: entry.address,
        name: Map.get(entry, :name),
        status: entry.status,
        error: Map.get(entry, :error),
        email_log_message_id: Map.get(entry, :email_log_message_id),
        attempted_at: if(entry.status == "pending", do: nil, else: now)
      }

      case repo.insert(row) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  @doc """
  The external recipients of a message as the mailbox `viewer_mailbox_uuid`
  may see them: all of them for the sending mailbox, To and Cc for anyone
  else (an external Bcc stays blind, like an internal one).
  """
  @spec list_for_viewer(binary(), binary() | nil) :: [ExternalRecipient.t()]
  def list_for_viewer(message_uuid, viewer_mailbox_uuid) when is_binary(message_uuid) do
    sender? =
      is_binary(viewer_mailbox_uuid) and
        from(m in Message,
          where: m.uuid == ^message_uuid and m.sender_mailbox_uuid == ^viewer_mailbox_uuid
        )
        |> repo().exists?()

    message_uuid
    |> list()
    |> Enum.filter(&(sender? or &1.role != "bcc"))
  end

  def list_for_viewer(_, _), do: []

  @doc "Every external recipient of a message, Bcc included — for its sender only."
  @spec list(binary()) :: [ExternalRecipient.t()]
  def list(message_uuid) when is_binary(message_uuid) do
    from(r in ExternalRecipient,
      where: r.message_uuid == ^message_uuid,
      order_by: [
        asc: fragment("array_position(ARRAY['to','cc','bcc']::varchar[], ?)", r.role),
        asc: r.inserted_at,
        asc: r.uuid
      ]
    )
    |> repo().all()
  end

  @doc """
  `:sent`, `:failed`, `:pending`, or `:unknown` — pending for more than 15
  minutes, so the outcome is in the email log, not here.
  """
  @spec display_status(ExternalRecipient.t(), DateTime.t()) ::
          :sent | :failed | :pending | :unknown
  def display_status(row, now \\ DateTime.utc_now())
  def display_status(%ExternalRecipient{status: "sent"}, _now), do: :sent
  def display_status(%ExternalRecipient{status: "failed"}, _now), do: :failed

  def display_status(%ExternalRecipient{status: "pending"} = row, now) do
    since = row.attempted_at || row.inserted_at

    if since && DateTime.diff(now, since) > @unknown_after_seconds,
      do: :unknown,
      else: :pending
  end

  # ── pubsub ──────────────────────────────────────────────────────────────────

  @doc """
  Subscribes the caller to the external-delivery updates of the messages
  sent from `mailbox_uuid`: `{:inbox_external_updated, message_uuid}`.
  """
  @spec subscribe(binary()) :: :ok | {:error, term()}
  def subscribe(mailbox_uuid), do: PubSub.subscribe(topic(mailbox_uuid))

  defp topic(mailbox_uuid), do: "phoenix_kit_inbox:external:#{mailbox_uuid}"

  defp broadcast(message) do
    PubSub.broadcast(
      topic(message.sender_mailbox_uuid),
      {:inbox_external_updated, to_string(message.uuid)}
    )
  rescue
    e -> Logger.warning("[Inbox] external status broadcast failed: #{Exception.message(e)}")
  end

  # ── sending ─────────────────────────────────────────────────────────────────

  @doc false
  # After the send's commit: sends the email to `rows` in a task under the
  # module's supervisor. When the task can't be started the rows fail at
  # once (and can be retried) rather than stay pending forever.
  @spec deliver_later(Message.t(), [ExternalRecipient.t()], Scope.t(), Mailbox.t()) :: :ok
  def deliver_later(%Message{} = message, rows, scope, mailbox) do
    uuids = Enum.map(rows, & &1.uuid)

    case start_task(fn -> deliver_now(message, uuids, scope, mailbox) end) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("[Inbox] could not start the external send: #{inspect(reason)}")
        finish(message, uuids, {:error, :not_started})
        :ok
    end
  end

  @doc false
  # Runs `fun` under the module's task supervisor.
  @spec start_task((-> term())) :: :ok | {:error, term()}
  def start_task(fun) do
    case Task.Supervisor.start_child(PhoenixKitInbox.TaskSupervisor, fun) do
      {:ok, _pid} -> :ok
      other -> {:error, other}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @doc false
  # The task's body: checks the sender again (identity and right, for
  # `scope` from `mailbox`), builds the email for the rows still pending
  # among `uuids` and sends it. A failed check or build fails the rows; once
  # the email went to the transport, its answer decides.
  @spec deliver_now(Message.t(), [binary()], Scope.t(), Mailbox.t()) :: :ok
  def deliver_now(%Message{} = message, uuids, scope, mailbox) do
    case pending_rows(message.uuid, uuids) do
      [] ->
        :ok

      rows ->
        result =
          with {:ok, identity} <- current_identity(scope, mailbox, message),
               :ok <- check_allowed(scope, identity),
               {:ok, email} <- build_email(message, rows, identity) do
            Outbound.deliver(email, context(message, identity, scope))
          end

        finish(message, Enum.map(rows, & &1.uuid), result)
        :ok
    end
  end

  defp check_allowed(scope, identity),
    do: if(allowed?(scope, identity), do: :ok, else: {:error, :forbidden})

  defp pending_rows(message_uuid, uuids) do
    from(r in ExternalRecipient,
      where: r.message_uuid == ^message_uuid and r.uuid in ^uuids and r.status == "pending",
      order_by: [asc: r.inserted_at, asc: r.uuid]
    )
    |> repo().all()
  end

  # The user who sends now: the sender, or whoever retries.
  defp context(message, identity, scope) do
    %{
      kind: :message,
      integration_uuid: identity["integration_uuid"],
      user_uuid: scope.user && scope.user.uuid && to_string(scope.user.uuid),
      message_uuid: to_string(message.uuid),
      identity_uuid: identity["uuid"]
    }
  end

  defp finish(message, uuids, result) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    changes =
      case result do
        {:ok, _} ->
          [
            status: "sent",
            error: nil,
            attempted_at: now,
            email_log_message_id: EmailLog.latest_message_id(to_string(message.uuid))
          ]

        {:error, reason} ->
          [status: "failed", error: describe_error(reason), attempted_at: now]
      end

    {_count, _} =
      from(r in ExternalRecipient, where: r.uuid in ^uuids and r.status == "pending")
      |> repo().update_all(set: changes)

    broadcast(message)
  rescue
    # The email went (or not) — the rows stay pending, which reads as
    # "unknown, check the email log" after a while; never as failed, which
    # would offer a retry of something that may have been sent.
    e -> Logger.error("[Inbox] could not record the external send: #{Exception.message(e)}")
  end

  defp describe_error(reason) do
    reason
    |> inspect(limit: 20, printable_limit: @max_error_length)
    |> String.slice(0, @max_error_length)
  end

  # ── the email ───────────────────────────────────────────────────────────────

  defp build_email(message, rows, identity) do
    attachments = Attachments.list_for_message(to_string(message.uuid))

    # Sizes as recorded first, so nothing is read for a message plainly too
    # large; then the bytes actually read — a size Storage did not know is
    # recorded as 0.
    with {:ok, from} <- from_address(identity),
         :ok <- check_size(Enum.map(attachments, & &1.size_bytes)),
         {:ok, files} <- read_attachments(attachments),
         :ok <- check_size(Enum.map(files, &byte_size(&1.data))) do
      email =
        Swoosh.Email.new()
        |> Swoosh.Email.from(from)
        |> Swoosh.Email.subject(message.subject || "")
        |> put_recipients(rows)
        |> put_reply_to(message.metadata)
        |> put_body(message)

      {:ok, Enum.reduce(files, email, &Swoosh.Email.attachment(&2, &1))}
    end
  rescue
    e -> {:error, {:build_failed, Exception.message(e)}}
  end

  defp from_address(%{"from_address" => address} = identity) when is_binary(address),
    do: {:ok, {identity["from_name"] || "", address}}

  defp from_address(_identity), do: {:error, :no_identity}

  defp put_recipients(email, rows) do
    Enum.reduce(rows, email, fn row, email ->
      recipient = {row.name || "", row.address}

      case row.role do
        "to" -> Swoosh.Email.to(email, recipient)
        "cc" -> Swoosh.Email.cc(email, recipient)
        "bcc" -> Swoosh.Email.bcc(email, recipient)
      end
    end)
  end

  defp put_reply_to(email, %{"reply_to" => address}) when is_binary(address) and address != "",
    do: Swoosh.Email.reply_to(email, address)

  defp put_reply_to(email, _metadata), do: email

  # The reader sees what the reading pane shows: Markdown as Body renders it.
  defp put_body(email, %Message{body_format: "markdown", body: body}) when is_binary(body) do
    email
    |> Swoosh.Email.html_body(body |> Body.markdown_html() |> Phoenix.HTML.safe_to_string())
    |> Swoosh.Email.text_body(Markdown.to_text(body, %{}))
  end

  defp put_body(email, %Message{body: body}), do: Swoosh.Email.text_body(email, body || "")

  defp read_attachments(attachments) do
    Enum.reduce_while(attachments, {:ok, []}, fn row, {:ok, acc} ->
      case read_attachment(row) do
        {:ok, file} -> {:cont, {:ok, [file | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      error -> error
    end
  end

  defp read_attachment(row) do
    case Attachments.read_file(row) do
      {:ok, path} ->
        try do
          {:ok,
           Swoosh.Attachment.new({:data, File.read!(path)},
             filename: row.filename,
             content_type: Attachments.safe_content_type(row.content_type)
           )}
        after
          File.rm(path)
        end

      {:error, _} ->
        {:error, {:attachment_unavailable, to_string(row.file_uuid)}}
    end
  end

  # ── retry ───────────────────────────────────────────────────────────────────

  @doc """
  Whether `retry/3` would be offered for `message` to its sending mailbox:
  a failed row, `phoenix_kit_emails` running, every log row failed or
  rejected, and not a recorded message. Does not check the scope.
  """
  @spec retry_available?(Message.t(), [ExternalRecipient.t()]) :: boolean()
  def retry_available?(%Message{} = message, rows) do
    Enum.any?(rows, &(&1.status == "failed")) and retry_check(message) == :ok
  end

  defp retry_check(%Message{metadata: %{"source" => "host"}}), do: {:error, :retry_unavailable}

  defp retry_check(message) do
    with true <- EmailLog.available?(),
         rows when is_list(rows) <- EmailLog.rows(to_string(message.uuid)) do
      if Enum.all?(rows, &(&1.status in @failed_log_statuses)),
        do: :ok,
        else: {:error, :external_maybe_delivered}
    else
      _ -> {:error, :retry_unavailable}
    end
  end

  @doc """
  Re-sends the failed external recipients of a message sent from `mailbox`
  (see the moduledoc). The sender's identity is checked again
  (`Identities.resolve/3`), as is the right to write externally. Returns
  `{:ok, :pending}` once the send is under way.
  """
  @spec retry(Scope.t(), Mailbox.t(), binary()) ::
          {:ok, :pending} | {:error, term()}
  def retry(%Scope{} = scope, mailbox, message_uuid) do
    with {:ok, fresh} <- Mailboxes.authorize_scope(scope, mailbox, "write"),
         {:ok, message} <- sent_message(fresh, message_uuid),
         :ok <- retry_check(message),
         {:ok, identity} <- current_identity(scope, fresh, message),
         :ok <- check_allowed(scope, identity),
         :ok <- Outbound.check_open(),
         {:ok, rows} <- claim_failed(message) do
      deliver_later(message, rows, scope, fresh)
      {:ok, :pending}
    end
  end

  def retry(_scope, _mailbox, _message_uuid), do: {:error, :forbidden}

  defp sent_message(mailbox, message_uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(message_uuid),
         %Message{} = message <-
           repo().get_by(Message, uuid: uuid, sender_mailbox_uuid: mailbox.uuid, status: "sent") do
      {:ok, message}
    else
      _ -> {:error, :message_not_found}
    end
  end

  # The message's identity as `scope` may send from it from `mailbox` now.
  defp current_identity(scope, mailbox, %Message{metadata: %{"identity" => %{"uuid" => uuid}}}) do
    case Identities.resolve(scope, uuid, mailbox) do
      {:ok, resolved} ->
        {:ok,
         %{
           "uuid" => resolved.identity_uuid,
           "kind" => resolved.kind,
           "integration_uuid" => resolved.integration_uuid,
           "from_address" => resolved.from_address,
           "from_name" => resolved.from_name
         }}

      {:error, reason} ->
        {:error, {:identity_unusable, reason}}
    end
  end

  defp current_identity(_scope, _mailbox, _message), do: {:error, :retry_unavailable}

  # failed -> pending in one statement: of two retries at once, one gets the
  # rows and the other nothing to send.
  defp claim_failed(message) do
    query =
      from(r in ExternalRecipient,
        where: r.message_uuid == ^message.uuid and r.status == "failed",
        select: r
      )

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case repo().update_all(query, set: [status: "pending", error: nil, attempted_at: now]) do
      {0, _} -> {:error, :nothing_to_retry}
      {_count, rows} -> {:ok, rows}
    end
  end
end
