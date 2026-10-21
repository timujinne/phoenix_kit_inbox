defmodule PhoenixKitInbox.Notify do
  @moduledoc """
  Side effects that fire after a message is delivered — activity logging,
  in-app notifications, and the optional outbound email nudge.

  Everything here is **best effort**. A notification that fails must never
  unsend a message that is already committed, so every function rescues, logs,
  and returns. Callers ignore the return value.

  ## The phoenix_kit_emails integration

  Inbox is an internal messaging system: messages live in this app's tables and
  are read in this app's UI. But a user who isn't looking at the app won't know
  a message arrived, so — **when the host also runs `phoenix_kit_emails`** — we
  send a short "you have a new message" nudge to the recipient's real email
  address.

  That integration is deliberately soft. `phoenix_kit_emails` is not in this
  module's `mix.exs`; `Code.ensure_loaded?/1` decides at runtime whether the
  nudge happens. Hosts running both modules get it for free, hosts running only
  Inbox are unaffected, and neither release cycle is coupled to the other.
  """

  require Logger

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Paths
  alias PhoenixKitInbox.Schemas.Mailbox
  alias PhoenixKitInbox.Schemas.Message

  @doc """
  Announces a sent message: one permanent `inbox.message_sent` activity for
  the send itself, one activity event per recipient (which core turns into
  that user's in-app notification), plus an optional email nudge.

  `bcc` recipients are notified like anyone else — they just don't appear in
  anyone else's recipient list.
  """
  @spec message_sent(Message.t(), Mailbox.t(), [%{role: String.t(), mailbox: Mailbox.t()}]) :: :ok
  def message_sent(%Message{} = message, %Mailbox{} = sender, recipients) do
    log_sent(message, recipients)

    Enum.each(recipients, fn %{mailbox: recipient_mailbox} ->
      notify_recipient(message, sender, recipient_mailbox)
    end)

    :ok
  end

  # The audit line for "this user sent a message": kept forever, and therefore
  # free of personal data — counts only, no subject, no addresses (those live
  # in the module's own tables, see `Messages.send_message/4`). No target, so
  # it notifies nobody.
  defp log_sent(message, recipients) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      PhoenixKit.Activity.log(%{
        action: "inbox.message_sent",
        module: "inbox",
        mode: "auto",
        actor_uuid: message.sender_user_uuid,
        resource_type: "inbox_message",
        resource_uuid: message.uuid,
        target_uuid: nil,
        permanent: true,
        metadata: %{
          "internal_recipients" => length(recipients),
          "external_recipients" => 0,
          "attachments" => 0
        }
      })
    end
  rescue
    e ->
      Logger.warning("[Inbox] activity logging failed: #{Exception.message(e)}")
      :error
  end

  defp notify_recipient(message, sender, recipient_mailbox) do
    recipient_mailbox
    |> readers()
    |> Enum.each(&log_activity(message, sender, recipient_mailbox, &1))

    send_email_nudge(message, sender, recipient_mailbox)
  end

  # Everyone who reads the mailbox: its owner and, for a shared one, every
  # grantee — each grant is at least "read". An ownerless mailbox (its user
  # was deleted) has nobody left to tell.
  defp readers(%Mailbox{kind: "shared"} = mailbox) do
    grantees = mailbox.uuid |> Mailboxes.list_grants() |> Enum.map(& &1.user_uuid)

    [mailbox.owner_uuid | grantees] |> Enum.reject(&is_nil/1) |> Enum.uniq()
  rescue
    e ->
      Logger.warning("[Inbox] could not list mailbox readers: #{Exception.message(e)}")
      Enum.reject([mailbox.owner_uuid], &is_nil/1)
  end

  defp readers(%Mailbox{owner_uuid: nil}), do: []
  defp readers(%Mailbox{owner_uuid: owner_uuid}), do: [owner_uuid]

  # ── activity / in-app notification ──────────────────────────────────────────

  # The canonical PhoenixKit pattern: you never write to the notifications
  # table. You log an activity with a `target_uuid`, and core turns it into that
  # user's notification (when target_uuid != actor_uuid).
  defp log_activity(message, sender, recipient_mailbox, target_uuid) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      PhoenixKit.Activity.log(%{
        action: "inbox.message_received",
        module: "inbox",
        mode: "auto",
        actor_uuid: message.sender_user_uuid,
        resource_type: "inbox_message",
        resource_uuid: message.uuid,
        target_uuid: target_uuid,
        metadata: %{
          "subject" => message.subject,
          "sender_mailbox" => sender.name,
          "notification_text" => notification_text(message, sender),
          "notification_icon" => "hero-envelope",
          # Raw path on purpose — core prefixes stored notification links
          # itself, and a pre-prefixed one comes out doubled.
          "notification_link" => Paths.raw_message_path(recipient_mailbox.uuid, message.uuid)
        }
      })
    end
  rescue
    e ->
      Logger.warning("[Inbox] activity logging failed: #{Exception.message(e)}")
      :error
  end

  defp notification_text(message, sender) do
    subject =
      case message.subject do
        nil -> "(no subject)"
        "" -> "(no subject)"
        subject -> subject
      end

    "#{sender.name}: #{subject}"
  end

  # ── outbound email nudge (soft dependency) ──────────────────────────────────

  defp send_email_nudge(message, sender, recipient_mailbox) do
    with true <- emails_module_available?(),
         true <- email_nudges_enabled?(),
         address when is_binary(address) <- nudge_address(recipient_mailbox) do
      deliver_nudge(address, message, sender, recipient_mailbox)
    else
      _ -> :skipped
    end
  rescue
    e ->
      Logger.warning("[Inbox] email nudge failed: #{Exception.message(e)}")
      :error
  end

  # Both the module and core's mailer have to be present. `phoenix_kit_emails`
  # intercepts and logs whatever core's mailer sends, so we deliver through
  # core and let the emails module do its tracking job.
  #
  # Called through `apply/3`, guarded by `function_exported?/3`. A literal
  # `PhoenixKit.Modules.Emails.enabled?()` — even via a bound variable — is a
  # compile-time "undefined function" warning here, and `mix precommit`
  # compiles with --warnings-as-errors. `apply/3` is the escape hatch core
  # itself uses for optional-module calls (see `PhoenixKit.Mailer` and
  # `PhoenixKitWeb.CommentsForwarding`), hence the credo exemption.
  defp emails_module, do: PhoenixKit.Modules.Emails

  defp emails_module_available? do
    mod = emails_module()

    Code.ensure_loaded?(mod) and function_exported?(mod, :enabled?, 0) and emails_enabled?(mod)
  rescue
    _ -> false
  end

  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp emails_enabled?(mod), do: apply(mod, :enabled?, [])

  # Host-controlled kill switch, off by default: a host that wants Inbox to be
  # purely in-app shouldn't start mailing people because they installed an
  # unrelated module.
  defp email_nudges_enabled? do
    PhoenixKit.Settings.get_boolean_setting("inbox_email_nudges_enabled", false)
  rescue
    _ -> false
  end

  @doc """
  Where the email nudge for `mailbox` goes: the owner's **current** login
  email for a personal mailbox (its `address` is a snapshot taken when it
  was created), the `address` of a shared one. `nil` when there is none.
  """
  @spec nudge_address(Mailbox.t()) :: String.t() | nil
  def nudge_address(%Mailbox{kind: "user", owner_uuid: owner_uuid}) when is_binary(owner_uuid) do
    case PhoenixKit.RepoHelper.repo().get(User, owner_uuid) do
      %User{email: email} when is_binary(email) and email != "" -> email
      _ -> nil
    end
  end

  def nudge_address(%Mailbox{kind: "user"}), do: nil

  def nudge_address(%Mailbox{address: address}) when is_binary(address) and address != "",
    do: address

  def nudge_address(_), do: nil

  # Built through core's mailer rather than a Swoosh adapter of our own, so the
  # host's configured provider, blocklist, and (when phoenix_kit_emails is
  # installed) tracking/queueing all apply without Inbox knowing about any of
  # it. `swoosh` arrives transitively via phoenix_kit — same as
  # phoenix_kit_newsletters' delivery worker.
  defp deliver_nudge(address, message, sender, recipient_mailbox) do
    subject = message.subject || "(no subject)"
    from_email = PhoenixKit.Settings.get_setting("from_email", "noreply@example.com")
    from_name = PhoenixKit.Settings.get_setting("from_name", "Inbox")

    body = """
    #{sender.name} sent you a message.

    Subject: #{subject}

    Read it: #{Paths.inbox(mailbox: recipient_mailbox.uuid, message: message.uuid)}
    """

    Swoosh.Email.new()
    |> Swoosh.Email.to(address)
    |> Swoosh.Email.from({from_name, from_email})
    |> Swoosh.Email.subject("New message: #{subject}")
    |> Swoosh.Email.text_body(body)
    |> PhoenixKit.Mailer.deliver_email()
  end

  @doc """
  Whether the outbound email nudge is currently wired up — used by the admin UI
  to explain why the toggle does or doesn't do anything on this host.
  """
  @spec email_nudges_available?() :: boolean()
  def email_nudges_available?, do: emails_module_available?()

  @doc """
  Names of recipients with no email address on file — for callers that want to
  warn "these people won't get an email nudge" before sending, rather than
  discovering it in the logs afterwards.
  """
  @spec unaddressable(list()) :: [String.t()]
  def unaddressable(recipients) do
    recipients
    |> Enum.filter(fn %{mailbox: mailbox} -> is_nil(nudge_address(mailbox)) end)
    |> Enum.map(fn %{mailbox: mailbox} -> mailbox.name end)
  end
end
