defmodule PhoenixKitInbox.Errors do
  @moduledoc """
  Central mapping from the error atoms this module's contexts return to
  translated, user-facing strings.

  Contexts return atoms (`{:error, :mailbox_access_denied}`); LiveViews call
  `message/1` at the flash boundary. Keeping the copy here means every "not
  found" reads identically across the three LiveViews, and translators have one
  file to work from.

  ## Example

      iex> PhoenixKitInbox.Errors.message(:message_not_found)
      "Message not found."
  """

  use Gettext, backend: PhoenixKitInbox.Gettext

  alias PhoenixKit.Utils.Format

  @doc """
  `message/1` for a person who is not the developer: what the application did
  not mean to say — a reason that is text (it came from somewhere else) and
  one with no message of its own — becomes the plain "could not be sent".
  For the places a host's code can answer through, like a compose form.
  """
  @spec user_message(term()) :: String.t()
  def user_message(reason) when is_binary(reason), do: message(:send_failed)

  def user_message(reason) do
    text = message(reason)
    if text == message_unexpected(reason), do: message(:send_failed), else: text
  end

  @doc "Translates an error reason into a user-facing string."
  @spec message(term()) :: String.t()
  def message(:mailbox_not_found), do: gettext("Mailbox not found.")
  def message(:message_not_found), do: gettext("Message not found.")
  def message(:recipient_not_found), do: gettext("Recipient not found.")
  def message(:no_recipients), do: gettext("Add at least one recipient.")
  def message(:invalid_user), do: gettext("Could not identify the current user.")

  def message(:forbidden), do: gettext("You don't have permission to do that.")

  def message(:mailbox_access_denied),
    do: gettext("You don't have access to this mailbox.")

  def message(:cannot_archive_personal_mailbox),
    do: gettext("Personal mailboxes can't be archived.")

  def message(:cannot_grant_personal_mailbox),
    do: gettext("Only shared mailboxes can be shared with others.")

  def message(:mailbox_archived),
    do: gettext("This mailbox is archived; it can't send.")

  def message(:opts_need_scope),
    do: gettext("These options need the sender's scope.")

  def message(:attachments_need_scope),
    do: gettext("Attachments need the sender's scope.")

  def message(:invalid_attachments), do: gettext("The attachments could not be read.")

  def message({:attachment_forbidden, _file_uuid}),
    do: gettext("You can't attach a file you don't have access to.")

  def message({:attachment_unavailable, _file_uuid}),
    do: gettext("A file can't be attached: it is in the trash or no longer available.")

  def message({:too_many_attachments, max}),
    do:
      ngettext(
        "A message can carry at most %{max} file.",
        "A message can carry at most %{max} files.",
        max,
        max: max
      )

  def message({:attachment_too_large, filename}),
    do: gettext("%{filename} is larger than the upload limit.", filename: filename)

  def message({:attachment_refused, _reason}),
    do: gettext("These attachments can't be sent to these recipients.")

  def message({:attachment_store_failed, _reason}),
    do: gettext("An attachment could not be stored. Try again.")

  def message(:storage_unsupported),
    do: gettext("Attachments are not supported by this installation's file storage.")

  def message(:uploads_in_progress), do: gettext("Wait for the uploads to finish.")

  def message(:not_found), do: gettext("Not found.")

  def message(:reply_to_not_allowed),
    do: gettext("You can't use that Reply-To address.")

  def message(:sender_options_need_scope),
    do: gettext("A sending identity and a Reply-To need the sender's scope.")

  def message({:identity_unusable, :broken}),
    do:
      gettext("That sender can't send right now: its mail connection is missing or disconnected.")

  def message({:identity_unusable, :not_found}), do: gettext("That sender no longer exists.")

  def message({:identity_unusable, :identity_not_for_mailbox}),
    do: gettext("That sender can't be used from this mailbox.")

  def message({:identity_unusable, _reason}),
    do: gettext("You can't send as that sender.")

  def message({:integration_unusable, :integration_missing}),
    do: gettext("That mail connection doesn't exist.")

  def message({:integration_unusable, :not_mail_provider}),
    do: gettext("That connection can't send email.")

  def message({:integration_unusable, :not_connected}),
    do: gettext("That mail connection isn't connected.")

  def message({:integration_unusable, :owner_mismatch}),
    do: gettext("That mail connection isn't available for this sender.")

  def message({:integration_unusable, :no_from_address}),
    do: gettext("That mail connection has no login email address to send from.")

  def message(:external_disabled),
    do: gettext("Sending to addresses outside this application is turned off.")

  def message(:external_needs_scope),
    do: gettext("Addresses outside this application need the sender's scope.")

  def message(:external_needs_identity),
    do: gettext("Choose a sender under “Send as” to write to addresses outside this application.")

  def message(:external_not_allowed),
    do: gettext("No mail is open to you for writing to addresses outside this application.")

  def message({:external_too_large, max}),
    do:
      gettext(
        "The attachments are too large for an email outside this application (at most %{size}).",
        size: Format.bytes(max)
      )

  def message({:filter_refused, _reason}),
    do: gettext("This installation's rules don't let that email leave the application.")

  def message(:filter_failed),
    do:
      gettext(
        "The email could not be checked against this installation's rules, so it was not sent."
      )

  def message(:no_integration), do: gettext("That sender has no mail connection.")

  def message(:retry_unavailable), do: gettext("This message can't be sent again from here.")

  def message(:external_maybe_delivered),
    do: gettext("The email log shows the email may have gone out, so it is not sent again.")

  def message(:nothing_to_retry), do: gettext("There is nothing to send again.")

  def message(:idempotency_key_taken),
    do: gettext("This send key was already used by someone else. Reopen the form and try again.")

  def message(:invalid_idempotency_key),
    do: gettext("The send key is not valid. Reopen the form and try again.")

  def message(:links_failed),
    do: gettext("The links to the related objects could not be saved; the message was not sent.")

  def message(:invalid_link), do: gettext("The link to the related object is not valid.")

  def message(:invalid_reply_to),
    do: gettext("The Reply-To address is not a valid email address.")

  def message(:html_body_too_large), do: gettext("The email's HTML is too large to send.")

  def message(:invalid_html_body), do: gettext("The email's HTML cannot be sent as it is.")

  def message({:internal_recipients, addresses}),
    do:
      gettext(
        "These addresses belong to people or mailboxes inside this application: %{addresses}.",
        addresses: Enum.join(addresses, ", ")
      )

  def message({:invalid_external_recipients, entries}),
    do: gettext("Not email addresses: %{entries}.", entries: Enum.join(entries, ", "))

  def message(:use_external_recipients),
    do:
      gettext("A recorded email names its recipients as external recipients, with their outcome.")

  def message({:library_unavailable, _reason}),
    do: gettext("Attachments are unavailable right now. Try again.")

  # Names the accepted forms. The bare "No mailbox matches: fotkin" left the
  # sender guessing whether the name was wrong, the person had no account, or
  # some other spelling was expected — and a username was in fact the one form
  # that never resolved.
  def message({:unknown_recipients, recipients}) do
    gettext(
      "No recipient matches: %{recipients}. Use @username, an email address, or a shared mailbox name.",
      recipients: Enum.join(recipients, ", ")
    )
  end

  def message({:invalid_recipient, entry}),
    do:
      gettext("Not a valid recipient: %{entry}. Add one address at a time.",
        entry: to_string(entry)
      )

  def message(:invalid_recipients), do: gettext("The recipients could not be read.")

  def message({:too_many_recipients, role, max}),
    do:
      gettext("At most %{max} addresses in %{field}.",
        max: max,
        field: role |> to_string() |> String.capitalize()
      )

  def message(:subject_too_long),
    do: gettext("The subject is too long (500 characters at most).")

  def message(:invalid_text), do: gettext("The text contains characters that can't be sent.")

  def message(:invalid_from), do: gettext("That sender is not valid.")

  def message({:member_as_email, addresses}),
    do:
      ngettext(
        "%{addresses} is inside this application. Choose them from the list as an internal recipient instead of typing the email.",
        "%{addresses} are inside this application. Choose them from the list as internal recipients instead of typing the email.",
        length(addresses),
        addresses: Enum.join(addresses, ", ")
      )

  def message({:route_mismatch, mismatches}),
    do:
      gettext(
        "These recipients would not be reached the way they were chosen: %{addresses}. Choose them again.",
        addresses: Enum.map_join(mismatches, ", ", & &1.address)
      )

  def message(:route_check_failed),
    do: gettext("The recipients could not be checked. Try again.")

  def message(:send_failed), do: gettext("The message could not be sent.")

  def message(:ambiguous_recipient),
    do: gettext("That name matches more than one recipient.")

  def message({:ambiguous_recipients, recipients}) do
    gettext("More than one recipient matches: %{recipients}. Use the full email address instead.",
      recipients: Enum.join(recipients, ", ")
    )
  end

  def message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} ->
      "#{field} #{Enum.join(messages, ", ")}"
    end)
  end

  def message(reason) when is_binary(reason), do: reason

  def message(reason), do: message_unexpected(reason)

  defp message_unexpected(reason) do
    gettext("Unexpected error: %{reason}", reason: inspect(reason))
  end
end
