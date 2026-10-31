defmodule PhoenixKitInbox.RecipientSources.Members do
  @moduledoc """
  The module's own `PhoenixKitInbox.RecipientSource`: the people inside the
  application (`PhoenixKitInbox.Members`) and the shared mailboxes, found by
  `PhoenixKitInbox.Mailboxes.search_recipients/3`. Everything it offers is
  delivered inside the application — route `:internal` — and nothing for a
  viewer without the `"inbox"` permission. Not the viewer themselves.
  """

  @behaviour PhoenixKitInbox.RecipientSource

  use Gettext, backend: PhoenixKitInbox.Gettext

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitInbox.Mailboxes

  @impl true
  @spec suggest(Scope.t() | nil, map(), String.t()) :: [
          PhoenixKitInbox.RecipientSource.suggestion()
        ]
  def suggest(%Scope{} = scope, _context, query) do
    with true <- Scope.can?(scope, "inbox"),
         {:ok, user_uuid} <- Mailboxes.scope_user_uuid(scope) do
      group = gettext("People and shared mailboxes")

      for %{handle: handle, label: label} <- Mailboxes.search_recipients(user_uuid, query) do
        %{address: handle, label: label, group: group, route: :internal}
      end
    else
      _ -> []
    end
  end

  def suggest(_scope, _context, _query), do: []
end
