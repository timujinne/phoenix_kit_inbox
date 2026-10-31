defmodule PhoenixKitInbox.Test.StrictHostLive do
  @moduledoc """
  A page that follows mail the way a host does (`MailExplorer.attach/3`) and
  has **no** catch-all `handle_info/2` — as most pages have none. A message
  the module's hook leaves in its mailbox after it is gone crashes it, so a
  test on this page shows what a lenient host would hide.

  Mounted at `/strict-host`; the session carries `"scope"` (`ComponentHostLive.stash/1`)
  and the filter `"filter"`. `{:test_detach, id}` detaches.
  """

  use Phoenix.LiveView

  alias PhoenixKitInbox.Web.Components.MailExplorer

  @impl true
  def mount(_params, session, socket) do
    {:stash, ref} = session["scope"]
    scope = :persistent_term.get({PhoenixKitInbox.Test.ComponentHostLive, ref})

    {:ok,
     socket
     |> assign(:phoenix_kit_current_scope, scope)
     |> MailExplorer.attach("demo", session["filter"])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <p id="strict-host">strict host</p>
    """
  end

  @impl true
  def handle_info({:test_detach, id}, socket), do: {:noreply, MailExplorer.detach(socket, id)}
end
