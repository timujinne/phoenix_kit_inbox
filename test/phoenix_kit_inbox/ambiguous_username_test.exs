defmodule PhoenixKitInbox.AmbiguousUsernameTest do
  @moduledoc """
  Usernames that differ only in case. Core made `username` a unique `citext`
  in V161, so a current install can't hold two of them — but this module
  supports cores before that, where the unique index is case-sensitive while
  recipients are matched with `lower()`. Each test drops the unique index
  inside its own sandbox transaction (rolled back at the end) to recreate
  that world; the DDL lock on the users table is why this is not async.
  """

  use PhoenixKitInbox.DataCase, async: false

  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages

  setup do
    Repo.query!("DROP INDEX IF EXISTS phoenix_kit_users_username_uidx")
    :ok
  end

  test "two members whose usernames differ only in case are ambiguous" do
    user_fixture(%{username: "Alice", email: "alice.one@example.com"})
    user_fixture(%{username: "alice", email: "alice.two@example.com"})

    for typed <- ["@alice", "alice", "ALICE"] do
      assert {:error, :ambiguous_recipient} = Mailboxes.fetch_mailbox_by_recipient(typed),
             "#{inspect(typed)} was not reported ambiguous"
    end
  end

  test "a send naming an ambiguous username is refused, naming the term" do
    sender = user_fixture()
    {:ok, mailbox} = Mailboxes.ensure_user_mailbox(sender)
    user_fixture(%{username: "Sam", email: "sam.one@example.com"})
    user_fixture(%{username: "sam", email: "sam.two@example.com"})

    assert {:error, {:ambiguous_recipients, ["@sam"]}} =
             Messages.send_message(mailbox, sender.uuid, %{"to" => "@sam", "subject" => "Hi"})
  end

  test "a non-member twin doesn't make a member's username ambiguous" do
    member = user_fixture(%{username: "Robin", email: "robin.staff@example.com"})

    user_fixture(%{
      username: "robin",
      email: "robin.customer@example.com",
      inbox_member: false
    })

    assert {:ok, %{owner_uuid: owner}} = Mailboxes.fetch_mailbox_by_recipient("@robin")
    assert owner == member.uuid
  end
end
