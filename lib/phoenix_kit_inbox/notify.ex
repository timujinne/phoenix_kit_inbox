defmodule PhoenixKitInbox.Notify do
  @moduledoc """
  Side effects that fire after a message is delivered — activity logging,
  in-app notifications, and the optional email nudge.

  Everything here is **best effort**. A notification that fails must never
  unsend a message that is already committed, so every function rescues, logs,
  and returns. Callers ignore the return value.

  ## The email nudge

  Inbox is an internal messaging system: messages live in this app's tables and
  are read in this app's UI. But a user who isn't looking at the app won't know
  a message arrived, so a short "you have a new message" email can go to the
  recipient's real address. It is off unless **all** of these hold:

    * the `inbox_email_nudges_enabled` setting is on;
    * a nudge sender is set — a shared identity named by the
      `inbox_nudge_identity_uuid` setting (`PhoenixKitInbox.set_nudge_identity/2`),
      whose system integration still works. Without one there is no nudge:
      it never falls back to core's default integration;
    * external sending is open (`PhoenixKitInbox.Outbound`) — a nudge is
      external mail and goes through the same filter.

  The nudges of a message are sent in one task under the module's task
  supervisor, after the commit, so the sender never waits for SMTP. When
  `phoenix_kit_emails` runs, it logs them like any other send.
  """

  use Gettext, backend: PhoenixKitInbox.Gettext

  require Logger

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.RecipientLocale
  alias PhoenixKitInbox.External
  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Outbound
  alias PhoenixKitInbox.Paths
  alias PhoenixKitInbox.Schemas.Mailbox
  alias PhoenixKitInbox.Schemas.Message

  @doc """
  Announces a sent message: one permanent `inbox.message_sent` activity for
  the send itself, one activity event per recipient (which core turns into
  that user's in-app notification), plus the email nudges.

  `counts` — `%{external: n, attachments: n}` — goes into the activity next
  to the number of internal recipients.

  `bcc` recipients are notified like anyone else — they just don't appear in
  anyone else's recipient list.
  """
  @spec message_sent(Message.t(), Mailbox.t(), [%{role: String.t(), mailbox: Mailbox.t()}], map()) ::
          :ok
  def message_sent(%Message{} = message, %Mailbox{} = sender, recipients, counts \\ %{}) do
    log_sent(message, length(recipients), counts)

    Enum.each(recipients, fn %{mailbox: recipient_mailbox} ->
      notify_recipient(message, sender, recipient_mailbox)
    end)

    send_email_nudges(message, sender, recipients)
    :ok
  end

  @doc """
  Logs the `inbox.message_sent` activity of a message the host recorded
  (`Messages.record_sent/4`) — it has no internal recipients to notify.
  """
  @spec message_recorded(Message.t(), map()) :: :ok
  def message_recorded(%Message{} = message, counts) do
    log_sent(message, 0, counts)
    :ok
  end

  # The audit line for "this user sent a message": kept forever, and therefore
  # free of personal data — counts only, no subject, no addresses (those live
  # in the module's own tables, see `Messages.send_message/4`). No target, so
  # it notifies nobody.
  defp log_sent(message, internal, counts) do
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
          "internal_recipients" => internal,
          "external_recipients" => Map.get(counts, :external, 0),
          "attachments" => Map.get(counts, :attachments, 0)
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
          "notification_text" => notification_text(message, sender, target_uuid),
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

  # Stored with the notification, so it is rendered once, in the language of
  # the person it is for — not of whoever happens to be sending.
  defp notification_text(message, sender, target_uuid) do
    RecipientLocale.in_locale(user_locale(target_uuid), fn ->
      subject =
        case message.subject do
          nil -> gettext("(no subject)")
          "" -> gettext("(no subject)")
          subject -> subject
        end

      "#{sender.name}: #{subject}"
    end)
  end

  # The locale a user reads in: their saved preference, else the site's
  # default. `nil` or an unknown user gets the site default.
  defp user_locale(user_uuid) do
    user = if is_binary(user_uuid), do: PhoenixKit.RepoHelper.repo().get(User, user_uuid)
    RecipientLocale.for_rendering(user)
  rescue
    e ->
      Logger.debug("[Inbox] reader locale lookup failed: #{Exception.message(e)}")
      RecipientLocale.for_rendering(nil)
  end

  defp mailbox_locale(%Mailbox{kind: "user", owner_uuid: owner_uuid}), do: user_locale(owner_uuid)
  defp mailbox_locale(_mailbox), do: user_locale(nil)

  # ── email nudge ─────────────────────────────────────────────────────────────

  defp send_email_nudges(message, sender, recipients) do
    with {:ok, identity} <- nudge_sender(),
         [_ | _] = nudges <- nudge_targets(recipients) do
      External.start_task(fn -> deliver_nudges(nudges, message, sender, identity) end)
    end
  rescue
    e ->
      Logger.warning("[Inbox] email nudge failed: #{Exception.message(e)}")
      :error
  end

  defp deliver_nudges(nudges, message, sender, identity) do
    Enum.each(nudges, fn {address, mailbox} ->
      deliver_nudge(address, message, sender, mailbox, identity)
    end)
  end

  # The identity the setting names, if nudges are on, external mail is open
  # and the identity still works — else no nudge at all.
  defp nudge_sender do
    with true <- PhoenixKitInbox.email_nudges_enabled?(),
         uuid when is_binary(uuid) <- PhoenixKitInbox.nudge_identity_uuid(),
         :ok <- Outbound.check_open(),
         {:ok, identity} <- Identities.resolve_system(uuid) do
      {:ok, identity}
    else
      _ -> :none
    end
  end

  defp nudge_targets(recipients) do
    Enum.flat_map(recipients, fn %{mailbox: mailbox} ->
      case nudge_address(mailbox) do
        address when is_binary(address) -> [{address, mailbox}]
        nil -> []
      end
    end)
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

  defp deliver_nudge(address, message, sender, recipient_mailbox, identity) do
    # The nudge runs in a task with no locale of its own: it is written in the
    # recipient's language (a shared mailbox has no one person — the site's).
    email =
      RecipientLocale.in_locale(mailbox_locale(recipient_mailbox), fn ->
        nudge_email(address, message, sender, recipient_mailbox, identity)
      end)

    email
    |> Outbound.deliver(%{
      kind: :nudge,
      integration_uuid: identity.integration_uuid,
      user_uuid: message.sender_user_uuid && to_string(message.sender_user_uuid),
      message_uuid: to_string(message.uuid),
      identity_uuid: identity.identity_uuid
    })
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.info("[Inbox] email nudge not sent: #{inspect(reason)}")
    end
  rescue
    e -> Logger.warning("[Inbox] email nudge failed: #{Exception.message(e)}")
  end

  defp nudge_email(address, message, sender, recipient_mailbox, identity) do
    subject = message.subject || gettext("(no subject)")

    body =
      Enum.join(
        [
          gettext("%{sender} sent you a message.", sender: sender.name),
          gettext("Subject: %{subject}", subject: subject),
          gettext("Read it: %{url}",
            url: Paths.inbox(mailbox: recipient_mailbox.uuid, message: message.uuid)
          )
        ],
        "\n\n"
      ) <> "\n"

    Swoosh.Email.new()
    |> Swoosh.Email.to(address)
    |> Swoosh.Email.from({identity.from_name, identity.from_address})
    |> Swoosh.Email.subject(gettext("New message: %{subject}", subject: subject))
    |> Swoosh.Email.text_body(body)
  end

  @doc """
  Whether the email nudge is wired up — a nudge sender is set and external
  sending is open — for a host's settings UI to explain why the toggle does or
  doesn't do anything on this host.
  """
  @spec email_nudges_available?() :: boolean()
  def email_nudges_available?,
    do: PhoenixKitInbox.nudge_identity_uuid() != nil and Outbound.open?()

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
