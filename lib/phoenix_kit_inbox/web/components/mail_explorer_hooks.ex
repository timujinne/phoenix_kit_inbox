defmodule PhoenixKitInbox.Web.Components.MailExplorerHooks do
  @moduledoc """
  What keeps a `MailExplorer` current on a host page: the subscriptions and
  the `handle_info` hook behind `MailExplorer.attach/3`.

  On a connected page `attach/3` subscribes (once, however many explorers the
  page holds) to

    * `PhoenixKitInbox.Links.subscribe/2` for each object of the filter: a
      letter linked to it or unlinked from it;
    * `PhoenixKitInbox.External.subscribe/1` for each mailbox the viewer can
      reach: the delivery status of an external recipient changed;
    * `PhoenixKitInbox.AccessEvents.subscribe_user/1`: a grant or a mailbox
      of the viewer changed — the list is read again and the status
      subscriptions follow the mailboxes the viewer reaches now.

  and a `:handle_info` hook turns these into `Phoenix.LiveView.send_update/3`
  calls to the explorers: an access event reads every list again; a link event
  reads the list of an explorer whose filter names an object the letter is
  linked to now, or that has the letter on its page (it may just have lost
  its link); a status event only if that letter is on the page. The hook
  **consumes** the three events (`:halt`): a page that attaches an explorer
  does not handle them itself.

  `attach/3` is idempotent per explorer `id`: calling it again with another
  filter replaces the explorer's filter, and the page follows the objects
  now wanted and lets go of the ones no explorer wants. `detach/2` forgets an
  explorer; the last one takes the hook and every subscription with it.

  The viewer is the scope in core's `:phoenix_kit_current_scope` assign, which
  every page of a PhoenixKit application has. Without a scope the page gets
  the link events only. Every update is a re-read with the viewer's access at
  that moment, so a missed or late event leaves a page stale, never exposed.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Phoenix.LiveView
  alias PhoenixKitInbox.AccessEvents
  alias PhoenixKitInbox.External
  alias PhoenixKitInbox.Links
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.ObjectMail
  alias PhoenixKitInbox.Web.Components.MailExplorer

  @hook :inbox_mail_explorers
  @key :inbox_mail_explorers

  @type object :: %{kind: String.t(), ref: String.t()}

  @doc false
  @spec attach(LiveView.Socket.t(), term(), [object()]) :: LiveView.Socket.t()
  def attach(socket, id, filter) when is_list(filter) do
    socket
    |> ensure_hook()
    |> register(id, ObjectMail.normalize_filter(filter))
    |> subscribe()
  end

  @doc false
  @spec detach(LiveView.Socket.t(), term()) :: LiveView.Socket.t()
  def detach(socket, id) do
    case Map.get(socket.assigns, @key) do
      nil ->
        socket

      state ->
        state = %{state | explorers: Map.delete(state.explorers, id)}
        socket = assign(socket, @key, state)

        if map_size(state.explorers) == 0,
          do: teardown(socket, state),
          else: subscribe(socket)
    end
  end

  # The state assign is nil, or absent, until the first `attach/3`, which puts
  # the hook with it.
  defp ensure_hook(socket) do
    if Map.get(socket.assigns, @key),
      do: socket,
      else: LiveView.attach_hook(socket, @hook, :handle_info, &__MODULE__.handle_info/2)
  end

  defp register(socket, id, filter) do
    state = state(socket)
    assign(socket, @key, %{state | explorers: Map.put(state.explorers, id, filter)})
  end

  defp state(socket) do
    Map.get(socket.assigns, @key) ||
      %{explorers: %{}, objects: MapSet.new(), mailboxes: MapSet.new(), user: nil}
  end

  # ── subscriptions ───────────────────────────────────────────────────────────

  defp subscribe(socket) do
    if LiveView.connected?(socket) do
      state =
        socket
        |> state()
        |> sync_objects()
        |> subscribe_user(socket)
        |> sync_mailboxes(socket)

      assign(socket, @key, state)
    else
      socket
    end
  end

  # The page follows exactly the objects its explorers' filters name.
  defp sync_objects(state) do
    wanted =
      state.explorers
      |> Map.values()
      |> List.flatten()
      |> MapSet.new(&{&1.kind, &1.ref})

    for {kind, ref} <- MapSet.difference(wanted, state.objects), do: Links.subscribe(kind, ref)

    for {kind, ref} <- MapSet.difference(state.objects, wanted),
        do: Links.unsubscribe(kind, ref)

    %{state | objects: wanted}
  end

  defp subscribe_user(%{user: nil} = state, socket) do
    case user_uuid(socket) do
      nil ->
        state

      user_uuid ->
        AccessEvents.subscribe_user(user_uuid)
        %{state | user: user_uuid}
    end
  end

  defp subscribe_user(state, _socket), do: state

  # The statuses of the letters the viewer sent come on the sending mailbox's
  # topic: follow the mailboxes they reach now, drop the ones they lost.
  defp sync_mailboxes(%{user: nil} = state, _socket), do: state

  defp sync_mailboxes(state, _socket) do
    reachable =
      state.user
      |> Mailboxes.list_accessible_mailboxes()
      |> MapSet.new(& &1.uuid)

    for uuid <- MapSet.difference(reachable, state.mailboxes), do: External.subscribe(uuid)
    for uuid <- MapSet.difference(state.mailboxes, reachable), do: External.unsubscribe(uuid)
    %{state | mailboxes: reachable}
  end

  # The last explorer is gone: nothing is followed, the hook is not there.
  defp teardown(socket, state) do
    if LiveView.connected?(socket) do
      sync_objects(state)
      for uuid <- state.mailboxes, do: External.unsubscribe(uuid)
      AccessEvents.unsubscribe_user(state.user)
    end

    socket
    |> LiveView.detach_hook(@hook, :handle_info)
    |> assign(@key, nil)
  end

  defp user_uuid(socket) do
    case Mailboxes.scope_user_uuid(socket.assigns[:phoenix_kit_current_scope]) do
      {:ok, uuid} -> uuid
      _ -> nil
    end
  end

  # ── events ──────────────────────────────────────────────────────────────────

  @doc false
  @spec handle_info(term(), LiveView.Socket.t()) :: {:cont | :halt, LiveView.Socket.t()}
  def handle_info({:inbox_message_linked, message_uuid}, socket) do
    objects = message_uuid |> Links.for_message() |> MapSet.new(&{&1.kind, &1.ref})

    for {id, filter} <- state(socket).explorers do
      if Enum.any?(filter, &MapSet.member?(objects, {&1.kind, &1.ref})),
        do: update_explorer(id, refresh: true),
        else: update_explorer(id, message_changed: message_uuid)
    end

    {:halt, socket}
  end

  def handle_info({:inbox_external_updated, message_uuid}, socket) do
    update_all(socket, message_changed: message_uuid)
    {:halt, socket}
  end

  def handle_info({:inbox_access_changed, _what}, socket) do
    state = state(socket)
    socket = assign(socket, @key, sync_mailboxes(state, socket))
    update_all(socket, refresh: true)
    {:halt, socket}
  end

  def handle_info(_message, socket), do: {:cont, socket}

  defp update_all(socket, assigns) do
    for {id, _filter} <- state(socket).explorers, do: update_explorer(id, assigns)
    :ok
  end

  defp update_explorer(id, assigns),
    do: LiveView.send_update(MailExplorer, [{:id, id} | assigns])
end
