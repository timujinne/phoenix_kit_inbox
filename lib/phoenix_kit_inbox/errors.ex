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

  use Gettext, backend: PhoenixKitWeb.Gettext

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

  def message(reason) do
    gettext("Unexpected error: %{reason}", reason: inspect(reason))
  end
end
