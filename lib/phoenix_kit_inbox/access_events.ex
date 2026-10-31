defmodule PhoenixKitInbox.AccessEvents do
  @moduledoc """
  Tells open Inbox pages that what a user may reach changed in a way core's
  scope refresh cannot know about: mailbox grants and senders are this
  module's own rows, not roles or permissions.

  Two topics, one message shape — `{:inbox_access_changed, what}`:

    * **per user** (`subscribe_user/1`) — `:mailboxes` when a grant is given
      or taken (its holder), a shared mailbox is created (its owner), or
      archived, restored or changed (its owner and every grant holder);
      `:senders` when one of the user's personal senders changes
    * **senders** (`subscribe_senders/0`) — `:senders` when a shared sender
      is created, changed (its roles, its mailbox) or deleted: who may use a
      common sender depends on roles, so every open page may be concerned

  Broadcast after the write committed. A failed broadcast is logged and
  never fails the write: a page that misses one is only as stale as it was
  before this module existed, and every action checks access again anyway.
  A page reloads what it derived from access on any of these messages — the
  same reload it runs on core's `phoenix_kit_scope_changed/1`.
  """

  require Logger

  alias PhoenixKit.PubSub.Manager, as: PubSub

  @senders_topic "phoenix_kit_inbox:access:senders"

  @doc "Subscribes the caller to `user_uuid`'s access changes."
  @spec subscribe_user(binary() | nil) :: :ok | {:error, term()}
  def subscribe_user(user_uuid) when is_binary(user_uuid),
    do: PubSub.subscribe(user_topic(user_uuid))

  def subscribe_user(_user_uuid), do: :ok

  @doc "Undoes `subscribe_user/1` for the caller."
  @spec unsubscribe_user(binary() | nil) :: :ok | {:error, term()}
  def unsubscribe_user(user_uuid) when is_binary(user_uuid),
    do: PubSub.unsubscribe(user_topic(user_uuid))

  def unsubscribe_user(_user_uuid), do: :ok

  @doc "Subscribes the caller to changes of the shared senders."
  @spec subscribe_senders() :: :ok | {:error, term()}
  def subscribe_senders, do: PubSub.subscribe(@senders_topic)

  @doc "Tells each of `user_uuids` that the mailboxes they reach changed."
  @spec mailboxes_changed([binary() | nil]) :: :ok
  def mailboxes_changed(user_uuids) do
    user_uuids
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.each(&broadcast(user_topic(&1), {:inbox_access_changed, :mailboxes}))
  end

  @doc """
  Tells whoever may be concerned that senders changed: everyone for a
  shared one (`nil`), the owner alone for a personal one.
  """
  @spec senders_changed(binary() | nil) :: :ok
  def senders_changed(nil), do: broadcast(@senders_topic, {:inbox_access_changed, :senders})

  def senders_changed(owner_uuid) when is_binary(owner_uuid),
    do: broadcast(user_topic(owner_uuid), {:inbox_access_changed, :senders})

  defp user_topic(user_uuid), do: "phoenix_kit_inbox:access:user:#{user_uuid}"

  defp broadcast(topic, message) do
    PubSub.broadcast(topic, message)
    :ok
  rescue
    e ->
      Logger.warning("[Inbox] access change broadcast failed: #{Exception.message(e)}")
      :ok
  end
end
