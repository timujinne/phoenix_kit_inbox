defmodule PhoenixKitInbox.ExternalReason do
  @moduledoc """
  Why an email to external addresses was not sent, in words.

  A failed `PhoenixKitInbox.Schemas.ExternalRecipient` keeps the reason as the
  `inspect/2` text of what `PhoenixKitInbox.External` got back (`:external_disabled`,
  `{:filter_refused, …}`, `{:transport_failed, "…"}`, …). `label/1` reads that
  text back into a translated sentence — no column and no migration, the stored
  text stays the technical detail. A reason it does not know, or none at all,
  is the plain "Sending failed."

  The label is **all** a reading pane shows: never the stored text, which for
  an answer of the transport carries the relay's host and the remote server's
  words — addresses, account data (`PhoenixKitInbox.Outbound` keeps the same
  rule for what it builds from a filter's answer). What a transport *returns*
  is recognised by its shape, not by its content:

    * Swoosh's SMTP adapter — `{type, message}` of `gen_smtp`: `:send`,
      `:retries_exceeded`, `:no_more_hosts` (the failure types nested inside,
      `:permanent_failure`, `:network_failure`, …, are listed too, in case an
      adapter hands one back directly);
    * an API adapter — `{status, body}` with an HTTP status;
    * a plain connection error (`:timeout`, `:closed`, `:econnrefused`,
      `:nxdomain`).

  All of them read "The mail server did not take the email.", like a
  transport that raised. A transport error of another shape is the plain
  "Sending failed." — never guessed, never shown.
  """

  use Gettext, backend: PhoenixKitInbox.Gettext

  alias PhoenixKitInbox.Errors

  # What the transport itself answers (see the moduledoc): the tags of
  # `gen_smtp`'s errors and the plain connection errors.
  @transport_atoms ~w(timeout closed econnrefused nxdomain)a
  @transport_tags ~w(permanent_failure temporary_failure network_failure tls_failed
                     auth_failed missing_requirement unexpected_response retries_exceeded
                     no_more_hosts send failed_connect)

  @atoms ~w(external_disabled no_integration filter_failed no_recipients not_started
            forbidden no_identity mailbox_archived mailbox_access_denied mailbox_not_found)a ++
           @transport_atoms
  @atom_names Map.new(@atoms, &{Atom.to_string(&1), &1})

  # Only the opening is matched: the stored text is cut at 500 characters, and
  # a long payload (`transport_failed` carries the transport's message) must
  # not cost the reason its label. Reasons that read their payload check the
  # closing brace themselves.
  @tuple ~r/\A\{:(\w+),\s*(.*)\z/s

  # An HTTP status first (`{550, body}`), nothing else begins a tuple with a number.
  @status ~r/\A\{[1-5]\d\d,/

  @doc """
  The translated reason for the stored `error` text of a failed row. Always a
  sentence: unknown or missing reasons read "Sending failed.".
  """
  @spec label(String.t() | nil) :: String.t()
  def label(error) do
    case parse(error) do
      {:ok, reason} -> describe(reason)
      :error -> gettext("Sending failed.")
    end
  end

  @doc "Whether `label/1` knows the reason (else it is the plain \"Sending failed.\")."
  @spec known?(String.t() | nil) :: boolean()
  def known?(error), do: match?({:ok, _}, parse(error))

  # The stored text is parsed back into a term without ever creating an atom:
  # the known names come from a fixed list.
  defp parse(":" <> name), do: Map.fetch(@atom_names, name)

  defp parse("{" <> _ = text) do
    case Regex.run(@tuple, text) do
      [_, tag, rest] -> tuple(tag, rest)
      _ -> if Regex.match?(@status, text), do: {:ok, {:transport_failed, nil}}, else: :error
    end
  end

  defp parse(_), do: :error

  defp tuple(tag, _rest) when tag in @transport_tags, do: {:ok, {:transport_failed, nil}}
  defp tuple("filter_refused", _rest), do: {:ok, {:filter_refused, nil}}
  defp tuple("transport_failed", _rest), do: {:ok, {:transport_failed, nil}}
  defp tuple("transport_exited", _rest), do: {:ok, {:transport_exited, nil}}
  defp tuple("build_failed", _rest), do: {:ok, {:build_failed, nil}}
  defp tuple("attachment_unavailable", _rest), do: {:ok, {:attachment_unavailable, nil}}

  defp tuple("external_too_large", rest) do
    case Integer.parse(rest) do
      {max, "}"} when max > 0 -> {:ok, {:external_too_large, max}}
      _ -> :error
    end
  end

  defp tuple("identity_unusable", ":broken}"), do: {:ok, {:identity_unusable, :broken}}
  defp tuple("identity_unusable", ":not_found}"), do: {:ok, {:identity_unusable, :not_found}}

  defp tuple("identity_unusable", ":identity_not_for_mailbox}"),
    do: {:ok, {:identity_unusable, :identity_not_for_mailbox}}

  defp tuple("identity_unusable", _rest), do: {:ok, {:identity_unusable, :other}}
  defp tuple(_tag, _rest), do: :error

  defp describe(:no_recipients), do: gettext("No recipient was left to send to.")
  defp describe(:not_started), do: gettext("The send could not be started.")

  defp describe(:forbidden),
    do: gettext("The sender is no longer allowed to send this email.")

  defp describe(:no_identity), do: gettext("The sender has no email address to send from.")

  defp describe({:transport_failed, _}), do: gettext("The mail server did not take the email.")
  defp describe(atom) when atom in @transport_atoms, do: describe({:transport_failed, nil})
  defp describe({:transport_exited, _}), do: gettext("The mail server did not take the email.")
  defp describe({:build_failed, _}), do: gettext("The email could not be built.")

  defp describe(reason), do: Errors.message(reason)
end
