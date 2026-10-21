defmodule PhoenixKitInbox.MessagesTest do
  use PhoenixKitInbox.DataCase, async: true

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Notify

  setup do
    enable_inbox!()
    alice = user_fixture()
    bob = user_fixture()
    carol = user_fixture()

    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)
    {:ok, carol_mb} = Mailboxes.ensure_user_mailbox(carol)

    %{
      alice: alice,
      bob: bob,
      carol: carol,
      alice_mb: alice_mb,
      bob_mb: bob_mb,
      carol_mb: carol_mb,
      alice_scope: scope_for(alice),
      bob_scope: scope_for(bob)
    }
  end

  describe "send_message/3" do
    test "delivers to the recipient's inbox and the sender's sent folder", ctx do
      assert {:ok, message} =
               Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
                 "to" => ctx.bob.email,
                 "subject" => "Hello",
                 "body" => "First message"
               })

      assert message.status == "sent"
      assert message.sent_at

      assert [%{message: received}] = Messages.list_folder(ctx.bob_mb.uuid, "inbox")
      assert received.uuid == message.uuid

      assert [%{message: sent}] = Messages.list_folder(ctx.alice_mb.uuid, "sent")
      assert sent.uuid == message.uuid

      # Nothing landed in the sender's own inbox.
      assert Messages.list_folder(ctx.alice_mb.uuid, "inbox") == []
    end

    test "the recipient's copy starts unseen, the sender's starts seen", ctx do
      {:ok, _} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
          "to" => ctx.bob.email,
          "subject" => "Unread me"
        })

      assert [%{delivery: received}] = Messages.list_folder(ctx.bob_mb.uuid, "inbox")
      assert is_nil(received.seen_at)

      assert [%{delivery: sent}] = Messages.list_folder(ctx.alice_mb.uuid, "sent")
      assert sent.seen_at
    end

    test "fans out to to/cc/bcc in one send", ctx do
      {:ok, message} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
          "to" => ctx.bob.email,
          "cc" => ctx.carol.email,
          "subject" => "Group"
        })

      assert length(Messages.list_folder(ctx.bob_mb.uuid, "inbox")) == 1
      assert length(Messages.list_folder(ctx.carol_mb.uuid, "inbox")) == 1

      roles = message.uuid |> Messages.list_recipients() |> Enum.map(& &1.role) |> Enum.sort()
      assert roles == ["cc", "to"]
    end

    test "accepts comma- and semicolon-separated recipient lists", ctx do
      {:ok, _} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
          "to" => "#{ctx.bob.email}, #{ctx.carol.email}",
          "subject" => "Both"
        })

      assert length(Messages.list_folder(ctx.bob_mb.uuid, "inbox")) == 1
      assert length(Messages.list_folder(ctx.carol_mb.uuid, "inbox")) == 1
    end

    test "a recipient listed twice gets one copy, keeping the stronger role", ctx do
      {:ok, message} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
          "to" => ctx.bob.email,
          "cc" => ctx.bob.email,
          "subject" => "Once"
        })

      assert length(Messages.list_folder(ctx.bob_mb.uuid, "inbox")) == 1
      assert [%{role: "to"}] = Messages.list_recipients(message.uuid)
    end

    test "an unknown recipient refuses the whole send", ctx do
      assert {:error, {:unknown_recipients, ["ghost@example.com"]}} =
               Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
                 "to" => "#{ctx.bob.email}, ghost@example.com",
                 "subject" => "Partial"
               })

      # The valid recipient got nothing — the send was atomic.
      assert Messages.list_folder(ctx.bob_mb.uuid, "inbox") == []
      assert Messages.list_folder(ctx.alice_mb.uuid, "sent") == []
    end

    test "sending with no recipients is refused", ctx do
      assert {:error, :no_recipients} =
               Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{"subject" => "To nobody"})
    end

    test "an entirely blank message is refused", ctx do
      assert {:error, changeset} =
               Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
                 "to" => ctx.bob.email,
                 "subject" => "  ",
                 "body" => ""
               })

      assert %{body: _} = errors_on(changeset)
    end

    test "a root message is its own thread", ctx do
      {:ok, message} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
          "to" => ctx.bob.email,
          "subject" => "Root"
        })

      assert message.thread_uuid == message.uuid
    end

    test "a reply inherits the parent's thread", ctx do
      {:ok, root} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
          "to" => ctx.bob.email,
          "subject" => "Root"
        })

      {:ok, reply} =
        Messages.send_message(ctx.bob_mb, ctx.bob.uuid, %{
          "to" => ctx.alice.email,
          "subject" => "Re: Root",
          "parent_uuid" => root.uuid
        })

      assert reply.thread_uuid == root.thread_uuid
      assert reply.uuid != reply.thread_uuid

      assert length(Messages.list_thread(root.thread_uuid)) == 2
    end
  end

  describe "who may send (send_message/3)" do
    test "a user with no access to the mailbox can't send from it", ctx do
      assert {:error, :mailbox_access_denied} =
               Messages.send_message(ctx.alice_mb, ctx.bob.uuid, %{
                 "to" => ctx.carol.email,
                 "subject" => "Spoofed"
               })

      assert Messages.list_folder(ctx.carol_mb.uuid, "inbox") == []
      assert Messages.list_folder(ctx.alice_mb.uuid, "sent") == []
    end

    test "a read grantee can't send as a shared mailbox; a write grantee can", ctx do
      shared = shared_mailbox_fixture(ctx.alice, %{name: "Team"})
      grant_fixture(shared, ctx.bob, "read")

      attrs = %{"to" => ctx.carol.email, "subject" => "From the team"}

      assert {:error, :mailbox_access_denied} = Messages.send_message(shared, ctx.bob.uuid, attrs)

      grant_fixture(shared, ctx.bob, "write")
      assert {:ok, _} = Messages.send_message(shared, ctx.bob.uuid, attrs)
    end

    test "no sender at all is refused, even for a mailbox that lost its owner", ctx do
      ctx.alice_mb |> Ecto.Changeset.change(owner_uuid: nil) |> Repo.update!()
      {:ok, orphan} = Mailboxes.fetch_mailbox(ctx.alice_mb.uuid)

      assert {:error, :mailbox_access_denied} =
               Messages.send_message(orphan, nil, %{"to" => ctx.bob.email, "subject" => "x"})
    end

    test "a non-member's email is refused like any unknown recipient", ctx do
      user_fixture(%{email: "client@example.com", inbox_member: false})

      assert {:error, {:unknown_recipients, ["client@example.com"]}} =
               Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
                 "to" => "client@example.com",
                 "subject" => "Hello"
               })
    end
  end

  describe "what a send may refer to" do
    test "an archived mailbox can't send, whatever the caller's struct says", ctx do
      shared = shared_mailbox_fixture(ctx.alice, %{name: "Retired desk"})
      stale = shared
      {:ok, _} = Mailboxes.archive_mailbox(ctx.alice_scope, shared)

      attrs = %{"to" => ctx.bob.email, "subject" => "From the grave"}

      assert {:error, :mailbox_archived} = Messages.send_message(ctx.alice_scope, stale, attrs)
      assert {:error, :mailbox_archived} = Messages.send_message(stale, ctx.alice.uuid, attrs)
      assert Messages.list_folder(ctx.bob_mb.uuid, "inbox") == []
    end

    test "a parent the sender can't read is dropped: the message starts its own thread", ctx do
      {:ok, private} =
        Messages.send_message(ctx.bob_mb, ctx.bob.uuid, %{
          "to" => ctx.carol.email,
          "subject" => "Bob and Carol only"
        })

      attrs = %{"to" => ctx.carol.email, "subject" => "Me too", "parent_uuid" => private.uuid}

      {:ok, scoped} = Messages.send_message(ctx.alice_scope, ctx.alice_mb, attrs)
      {:ok, legacy} = Messages.send_message(ctx.alice_mb, ctx.alice.uuid, attrs)

      {:ok, junk} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{attrs | "parent_uuid" => "junk"})

      {:ok, draft} =
        Messages.save_draft(ctx.alice_scope, ctx.alice_mb, %{"parent_uuid" => private.uuid})

      for message <- [scoped, legacy, junk, draft] do
        assert message.parent_uuid == nil
        assert message.thread_uuid == message.uuid
      end

      assert Messages.list_thread(private.thread_uuid) |> length() == 1
    end

    test "a reply to a reply stays in the root's thread", ctx do
      {:ok, root} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
          "to" => ctx.bob.email,
          "subject" => "1"
        })

      {:ok, reply} =
        Messages.send_message(ctx.bob_scope, ctx.bob_mb, %{
          "to" => ctx.alice.email,
          "subject" => "2",
          "parent_uuid" => root.uuid
        })

      {:ok, reply_to_reply} =
        Messages.send_message(ctx.alice_scope, ctx.alice_mb, %{
          "to" => ctx.bob.email,
          "subject" => "3",
          "parent_uuid" => reply.uuid
        })

      assert reply.parent_uuid == root.uuid
      assert reply_to_reply.parent_uuid == reply.uuid

      for message <- [root, reply, reply_to_reply] do
        assert message.thread_uuid == root.uuid
      end

      assert root.thread_uuid |> Messages.list_thread() |> Enum.map(& &1.uuid) ==
               [root.uuid, reply.uuid, reply_to_reply.uuid]
    end

    test "a thread keeps its order when messages share an inserted_at second", ctx do
      {:ok, root} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
          "to" => ctx.bob.email,
          "subject" => "1"
        })

      {:ok, reply} =
        Messages.send_message(ctx.bob_scope, ctx.bob_mb, %{
          "to" => ctx.alice.email,
          "subject" => "2",
          "parent_uuid" => root.uuid
        })

      {:ok, last} =
        Messages.send_message(ctx.alice_scope, ctx.alice_mb, %{
          "to" => ctx.bob.email,
          "subject" => "3",
          "parent_uuid" => reply.uuid
        })

      # Same second for all three (inserted_at has second precision), rows
      # rewritten out of order so their physical order is not the thread's.
      same = ~U[2026-01-01 00:00:00Z]

      for message <- [reply, root, last] do
        message |> Ecto.Changeset.change(inserted_at: same) |> Repo.update!()
      end

      assert root.thread_uuid |> Messages.list_thread() |> Enum.map(& &1.uuid) ==
               [root.uuid, reply.uuid, last.uuid]
    end

    test "a caller-supplied thread_uuid doesn't put a draft in someone else's thread", ctx do
      {:ok, private} =
        Messages.send_message(ctx.bob_mb, ctx.bob.uuid, %{
          "to" => ctx.carol.email,
          "subject" => "x"
        })

      {:ok, draft} =
        Messages.save_draft(ctx.alice_scope, ctx.alice_mb, %{"thread_uuid" => private.thread_uuid})

      assert draft.thread_uuid == draft.uuid
    end

    test "a parent held in another of the sender's mailboxes keeps the thread", ctx do
      shared = shared_mailbox_fixture(ctx.alice, %{name: "Alice's desk"})

      {:ok, original} =
        Messages.send_message(ctx.bob_mb, ctx.bob.uuid, %{
          "to" => ctx.alice.email,
          "subject" => "Q"
        })

      {:ok, reply} =
        Messages.send_message(ctx.alice_scope, shared, %{
          "to" => ctx.bob.email,
          "subject" => "A",
          "parent_uuid" => original.uuid
        })

      assert reply.parent_uuid == original.uuid
      assert reply.thread_uuid == original.thread_uuid
    end

    test "a draft whose parent copy was purged since can still be saved and sent", ctx do
      {:ok, original} =
        Messages.send_message(ctx.bob_mb, ctx.bob.uuid, %{
          "to" => ctx.alice.email,
          "subject" => "Q"
        })

      {:ok, draft} =
        Messages.save_draft(ctx.alice_scope, ctx.alice_mb, %{
          "parent_uuid" => original.uuid,
          "subject" => "Re: Q"
        })

      assert draft.thread_uuid == original.thread_uuid
      :ok = Messages.purge(ctx.alice_scope, ctx.alice_mb, original.uuid)

      assert {:ok, resaved} =
               Messages.save_draft(ctx.alice_scope, ctx.alice_mb, %{
                 "uuid" => draft.uuid,
                 "subject" => "Re: Q"
               })

      assert {:ok, sent} =
               Messages.send_message(ctx.alice_scope, ctx.alice_mb, %{
                 "uuid" => resaved.uuid,
                 "to" => ctx.bob.email,
                 "subject" => "Re: Q"
               })

      assert sent.uuid == draft.uuid
      assert sent.parent_uuid == nil
      assert sent.thread_uuid == sent.uuid
    end

    test "the sender's own message stays a valid parent after its sent copy is purged", ctx do
      {:ok, mine} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
          "to" => ctx.bob.email,
          "subject" => "1"
        })

      :ok = Messages.purge(ctx.alice_scope, ctx.alice_mb, mine.uuid)

      {:ok, follow_up} =
        Messages.send_message(ctx.alice_scope, ctx.alice_mb, %{
          "to" => ctx.bob.email,
          "subject" => "2",
          "parent_uuid" => mine.uuid
        })

      assert follow_up.thread_uuid == mine.thread_uuid
    end

    test "a reply to a message the mailbox holds joins its thread", ctx do
      {:ok, original} =
        Messages.send_message(ctx.bob_mb, ctx.bob.uuid, %{
          "to" => ctx.alice.email,
          "subject" => "Q"
        })

      assert {:ok, reply} =
               Messages.send_message(ctx.alice_scope, ctx.alice_mb, %{
                 "to" => ctx.bob.email,
                 "subject" => "A",
                 "parent_uuid" => original.uuid
               })

      assert reply.thread_uuid == original.thread_uuid
    end

    test "the legacy form refuses server-side options instead of dropping them", ctx do
      assert {:error, :opts_need_scope} =
               Messages.send_message(
                 ctx.alice_mb,
                 ctx.alice.uuid,
                 %{"to" => ctx.bob.email, "subject" => "x"},
                 attachments_authorized: ["x"]
               )
    end
  end

  describe "send_message/4 with a scope" do
    test "sends as the scope's user", ctx do
      assert {:ok, message} =
               Messages.send_message(ctx.alice_scope, ctx.alice_mb, %{
                 "to" => "@#{ctx.bob.username}",
                 "subject" => "Scoped"
               })

      assert message.sender_user_uuid == ctx.alice.uuid
      assert [%{message: %{uuid: uuid}}] = Messages.list_folder(ctx.bob_mb.uuid, "inbox")
      assert uuid == message.uuid
    end

    test "is refused without the inbox permission", ctx do
      scope = scope_for(ctx.alice, [])

      assert {:error, :forbidden} =
               Messages.send_message(scope, ctx.alice_mb, %{
                 "to" => ctx.bob.email,
                 "subject" => "x"
               })

      assert Messages.list_folder(ctx.bob_mb.uuid, "inbox") == []
    end

    test "is refused from someone else's mailbox", ctx do
      assert {:error, :mailbox_access_denied} =
               Messages.send_message(ctx.alice_scope, ctx.bob_mb, %{
                 "to" => ctx.carol.email,
                 "subject" => "Not mine"
               })
    end

    test "an anonymous scope is refused", ctx do
      assert {:error, :forbidden} =
               Messages.send_message(Scope.for_user(nil), ctx.alice_mb, %{
                 "to" => ctx.bob.email,
                 "subject" => "x"
               })
    end
  end

  describe "the send record" do
    test "the sender's name and email are kept on the message", ctx do
      {:ok, message} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
          "to" => ctx.bob.email,
          "bcc" => ctx.carol.email,
          "subject" => "Kept"
        })

      assert message.metadata["sender"] == %{
               "user_uuid" => ctx.alice.uuid,
               "name" => Mailboxes.user_display_name(ctx.alice),
               "email" => ctx.alice.email,
               "mailbox" => ctx.alice_mb.name
             }

      roles = Map.new(message.metadata["recipients"], &{&1["mailbox_uuid"], &1["role"]})
      assert roles == %{ctx.bob_mb.uuid => "to", ctx.carol_mb.uuid => "bcc"}

      names = Enum.map(message.metadata["recipients"], & &1["name"])
      assert ctx.bob_mb.name in names
    end

    test "a recipient is recorded by their name and handle at send time", ctx do
      # The mailbox name was frozen when the mailbox was created.
      ctx.bob
      |> Ecto.Changeset.change(first_name: "Robert", last_name: "Renamed")
      |> Repo.update!()

      shared = shared_mailbox_fixture(ctx.carol, %{name: "Desk", address: "desk@example.com"})

      {:ok, message} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
          "to" => "#{ctx.bob.email}, desk@example.com",
          "subject" => "Who"
        })

      by_mailbox = Map.new(message.metadata["recipients"], &{&1["mailbox_uuid"], &1})

      assert %{"name" => "Robert Renamed", "handle" => handle} = by_mailbox[ctx.bob_mb.uuid]
      assert handle == "@#{ctx.bob.username}"
      assert %{"name" => "Desk", "handle" => "desk@example.com"} = by_mailbox[shared.uuid]
    end

    test "the recipient snapshot shows bcc only to the sender and to that bcc", ctx do
      {:ok, message} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
          "to" => ctx.bob.email,
          "bcc" => ctx.carol.email,
          "subject" => "Snapshot"
        })

      roles = fn entries -> entries |> Enum.map(& &1["mailbox_uuid"]) |> Enum.sort() end

      assert roles.(Messages.recipient_snapshot(message, ctx.alice_mb.uuid)) ==
               Enum.sort([ctx.bob_mb.uuid, ctx.carol_mb.uuid])

      assert roles.(Messages.recipient_snapshot(message, ctx.bob_mb.uuid)) == [ctx.bob_mb.uuid]

      assert roles.(Messages.recipient_snapshot(message, ctx.carol_mb.uuid)) ==
               Enum.sort([ctx.bob_mb.uuid, ctx.carol_mb.uuid])

      # The reading paths hand out the filtered snapshot.
      {:ok, %{message: as_bob}} = Messages.fetch_for_mailbox(ctx.bob_mb.uuid, message.uuid)
      assert roles.(as_bob.metadata["recipients"]) == [ctx.bob_mb.uuid]

      [%{message: listed}] = Messages.list_folder(ctx.bob_mb.uuid, "inbox")
      assert roles.(listed.metadata["recipients"]) == [ctx.bob_mb.uuid]

      [threaded] = Messages.list_thread(message.thread_uuid)
      assert roles.(threaded.metadata["recipients"]) == [ctx.bob_mb.uuid]

      {:ok, %{message: as_sender}} = Messages.fetch_for_mailbox(ctx.alice_mb.uuid, message.uuid)
      assert length(as_sender.metadata["recipients"]) == 2
    end

    test "a caller can't forge the sender snapshot", ctx do
      {:ok, message} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
          "to" => ctx.bob.email,
          "subject" => "Forged",
          "metadata" => %{"sender" => %{"name" => "Somebody else"}, "ref" => "order-1"}
        })

      assert message.metadata["sender"]["name"] == Mailboxes.user_display_name(ctx.alice)
      assert message.metadata["ref"] == "order-1"
    end

    test "a nil metadata from the caller is treated as none", ctx do
      assert {:ok, message} =
               Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
                 "to" => ctx.bob.email,
                 "subject" => "No meta",
                 "metadata" => nil
               })

      assert message.metadata["sender"]["user_uuid"] == ctx.alice.uuid

      assert {:ok, _draft} =
               Messages.save_draft(ctx.alice_scope, ctx.alice_mb, %{"metadata" => nil})
    end

    test "one permanent inbox.message_sent activity with counts only", ctx do
      {:ok, message} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
          "to" => ctx.bob.email,
          "cc" => ctx.carol.email,
          "subject" => "Private subject"
        })

      assert [row] = sent_activities(message.uuid)
      assert row.actor_uuid == ctx.alice.uuid
      assert row.target_uuid == nil
      assert row.permanent == true

      assert row.metadata == %{
               "internal_recipients" => 2,
               "external_recipients" => 0,
               "attachments" => 0
             }
    end
  end

  describe "notifications" do
    test "a shared mailbox's message notifies its owner and every grantee", ctx do
      shared = shared_mailbox_fixture(ctx.carol, %{name: "Ops"})
      grant_fixture(shared, ctx.bob, "read")
      dave = user_fixture()
      grant_fixture(shared, dave, "admin")

      {:ok, message} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{"to" => "ops", "subject" => "Ping"})

      assert received_targets(message.uuid) ==
               Enum.sort([ctx.carol.uuid, ctx.bob.uuid, dave.uuid])
    end

    test "a personal mailbox's message notifies its owner once", ctx do
      {:ok, message} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
          "to" => ctx.bob.email,
          "subject" => "Ping"
        })

      assert received_targets(message.uuid) == [ctx.bob.uuid]
    end

    test "the email nudge for a personal mailbox goes to the owner's current email", ctx do
      ctx.bob |> Ecto.Changeset.change(email: "bob.new@example.com") |> Repo.update!()

      assert ctx.bob_mb.address != "bob.new@example.com"
      assert Notify.nudge_address(ctx.bob_mb) == "bob.new@example.com"
    end

    test "the email nudge for a shared mailbox goes to its address", ctx do
      shared = shared_mailbox_fixture(ctx.carol, %{name: "Desk", address: "desk@example.com"})

      assert Notify.nudge_address(shared) == "desk@example.com"
    end
  end

  describe "who sees a bcc" do
    setup ctx do
      dave = user_fixture()
      {:ok, dave_mb} = Mailboxes.ensure_user_mailbox(dave)

      {:ok, message} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
          "to" => ctx.bob.email,
          "bcc" => "#{ctx.carol.email}, #{dave.email}",
          "subject" => "Blind"
        })

      %{message: message, dave_mb: dave_mb}
    end

    defp visible(message, mailbox) do
      message.uuid
      |> Messages.list_recipients(mailbox.uuid)
      |> Map.new(&{&1.mailbox.uuid, &1.role})
    end

    test "the sender sees every recipient", ctx do
      assert visible(ctx.message, ctx.alice_mb) == %{
               ctx.bob_mb.uuid => "to",
               ctx.carol_mb.uuid => "bcc",
               ctx.dave_mb.uuid => "bcc"
             }
    end

    test "a to recipient sees no bcc", ctx do
      assert visible(ctx.message, ctx.bob_mb) == %{ctx.bob_mb.uuid => "to"}
    end

    test "a bcc recipient sees their own row, not the other bcc", ctx do
      assert visible(ctx.message, ctx.carol_mb) == %{
               ctx.bob_mb.uuid => "to",
               ctx.carol_mb.uuid => "bcc"
             }
    end
  end

  describe "drafts" do
    test "saving creates one delivery in the author's drafts folder", ctx do
      assert {:ok, draft} =
               Messages.save_draft(ctx.alice_scope, ctx.alice_mb, %{
                 "subject" => "Half written",
                 "body" => "..."
               })

      assert draft.status == "draft"
      assert [%{message: listed}] = Messages.list_folder(ctx.alice_mb.uuid, "drafts")
      assert listed.uuid == draft.uuid
    end

    test "re-saving updates the same message rather than creating another", ctx do
      {:ok, draft} = Messages.save_draft(ctx.alice_scope, ctx.alice_mb, %{"subject" => "v1"})

      {:ok, updated} =
        Messages.save_draft(ctx.alice_scope, ctx.alice_mb, %{
          "uuid" => draft.uuid,
          "subject" => "v2"
        })

      assert updated.uuid == draft.uuid
      assert updated.subject == "v2"
      assert length(Messages.list_folder(ctx.alice_mb.uuid, "drafts")) == 1
    end

    test "a draft with no recipients is fine — validation happens at send", ctx do
      assert {:ok, _} = Messages.save_draft(ctx.alice_scope, ctx.alice_mb, %{"subject" => ""})
    end

    test "sending a draft promotes the same row and empties the drafts folder", ctx do
      {:ok, draft} = Messages.save_draft(ctx.alice_scope, ctx.alice_mb, %{"subject" => "Ready"})

      {:ok, sent} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
          "uuid" => draft.uuid,
          "to" => ctx.bob.email,
          "subject" => "Ready"
        })

      assert sent.uuid == draft.uuid
      assert sent.status == "sent"
      assert Messages.list_folder(ctx.alice_mb.uuid, "drafts") == []
      assert length(Messages.list_folder(ctx.alice_mb.uuid, "sent")) == 1
      assert length(Messages.list_folder(ctx.bob_mb.uuid, "inbox")) == 1
    end

    test "deleting a draft removes it and its delivery", ctx do
      {:ok, draft} = Messages.save_draft(ctx.alice_scope, ctx.alice_mb, %{"subject" => "Nope"})

      assert :ok = Messages.delete_draft(ctx.alice_scope, ctx.alice_mb, draft.uuid)
      assert Messages.list_folder(ctx.alice_mb.uuid, "drafts") == []
    end

    test "a draft keeps its recipients as typed, half-typed ones included", ctx do
      {:ok, draft} =
        Messages.save_draft(ctx.alice_scope, ctx.alice_mb, %{
          "to" => "@#{ctx.bob.username}, half-typ",
          "cc" => ["#{ctx.carol.email}"],
          "bcc" => "",
          "subject" => "With people"
        })

      assert Messages.draft_recipients(draft) == %{
               "to" => "@#{ctx.bob.username}, half-typ",
               "cc" => ctx.carol.email,
               "bcc" => ""
             }

      {:ok, again} =
        Messages.save_draft(ctx.alice_scope, ctx.alice_mb, %{
          "uuid" => draft.uuid,
          "to" => ctx.bob.email,
          "subject" => "With people"
        })

      assert Messages.draft_recipients(again) == %{"to" => ctx.bob.email, "cc" => "", "bcc" => ""}
    end

    test "sending a draft drops the saved recipient text", ctx do
      {:ok, draft} =
        Messages.save_draft(ctx.alice_scope, ctx.alice_mb, %{
          "to" => ctx.bob.email,
          "subject" => "Go"
        })

      {:ok, sent} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
          "uuid" => draft.uuid,
          "to" => ctx.bob.email,
          "subject" => "Go"
        })

      refute Map.has_key?(sent.metadata, "draft_recipients")
    end

    test "nobody saves a draft into a mailbox they can't write to", ctx do
      assert {:error, :mailbox_access_denied} =
               Messages.save_draft(ctx.bob_scope, ctx.alice_mb, %{"subject" => "Planted"})

      assert Messages.list_folder(ctx.alice_mb.uuid, "drafts") == []
    end

    test "you can't delete someone else's draft", ctx do
      {:ok, draft} = Messages.save_draft(ctx.alice_scope, ctx.alice_mb, %{"subject" => "Mine"})

      assert {:error, :message_not_found} =
               Messages.delete_draft(ctx.bob_scope, ctx.bob_mb, draft.uuid)
    end
  end

  describe "per-mailbox state" do
    setup ctx do
      {:ok, message} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
          "to" => "#{ctx.bob.email}, #{ctx.carol.email}",
          "subject" => "Shared thread",
          "body" => "Body text"
        })

      Map.put(ctx, :message, message)
    end

    test "marking seen in one mailbox doesn't touch the other", ctx do
      assert {:ok, _} = Messages.mark_seen(ctx.bob_scope, ctx.bob_mb, ctx.message.uuid)

      assert [%{delivery: bobs}] = Messages.list_folder(ctx.bob_mb.uuid, "inbox")
      assert bobs.seen_at

      assert [%{delivery: carols}] = Messages.list_folder(ctx.carol_mb.uuid, "inbox")
      assert is_nil(carols.seen_at)
    end

    test "mark_seen is idempotent and keeps the original stamp", ctx do
      {:ok, first} = Messages.mark_seen(ctx.bob_scope, ctx.bob_mb, ctx.message.uuid)
      {:ok, second} = Messages.mark_seen(ctx.bob_scope, ctx.bob_mb, ctx.message.uuid)

      assert first.seen_at == second.seen_at
    end

    test "mark_unseen clears the stamp", ctx do
      {:ok, _} = Messages.mark_seen(ctx.bob_scope, ctx.bob_mb, ctx.message.uuid)
      assert {:ok, delivery} = Messages.mark_unseen(ctx.bob_scope, ctx.bob_mb, ctx.message.uuid)
      assert is_nil(delivery.seen_at)
    end

    test "starring is per mailbox", ctx do
      assert {:ok, %{starred: true}} =
               Messages.toggle_star(ctx.bob_scope, ctx.bob_mb, ctx.message.uuid)

      assert [%{delivery: %{starred: false}}] = Messages.list_folder(ctx.carol_mb.uuid, "inbox")
    end

    test "moving to trash takes it out of the inbox listing", ctx do
      assert {:ok, _} =
               Messages.move_to_folder(ctx.bob_scope, ctx.bob_mb, ctx.message.uuid, "trash")

      assert Messages.list_folder(ctx.bob_mb.uuid, "inbox") == []
      assert length(Messages.list_folder(ctx.bob_mb.uuid, "trash")) == 1

      # Carol's copy is untouched.
      assert length(Messages.list_folder(ctx.carol_mb.uuid, "inbox")) == 1
    end

    test "purging removes only this mailbox's copy", ctx do
      assert :ok = Messages.purge(ctx.bob_scope, ctx.bob_mb, ctx.message.uuid)

      assert Messages.list_folder(ctx.bob_mb.uuid, "inbox") == []

      assert {:error, :message_not_found} =
               Messages.fetch_for_mailbox(ctx.bob_mb.uuid, ctx.message.uuid)

      assert length(Messages.list_folder(ctx.carol_mb.uuid, "inbox")) == 1
      assert {:ok, _} = Messages.fetch_for_mailbox(ctx.carol_mb.uuid, ctx.message.uuid)
    end

    test "a mailbox can't read a message it was never sent", ctx do
      stranger = user_fixture()
      {:ok, stranger_mb} = Mailboxes.ensure_user_mailbox(stranger)

      assert {:error, :message_not_found} =
               Messages.fetch_for_mailbox(stranger_mb.uuid, ctx.message.uuid)
    end

    test "unseen counts are per folder", ctx do
      assert %{"inbox" => 1} = Mailboxes.unseen_counts(ctx.bob_mb.uuid)

      {:ok, _} = Messages.mark_seen(ctx.bob_scope, ctx.bob_mb, ctx.message.uuid)
      assert Mailboxes.unseen_counts(ctx.bob_mb.uuid) == %{}
    end
  end

  describe "delivery state refuses a forged caller" do
    setup ctx do
      shared = shared_mailbox_fixture(ctx.carol, %{name: "Front"})
      reader = user_fixture()
      writer = user_fixture()
      grant_fixture(shared, reader, "read")
      grant_fixture(shared, writer, "write")

      {:ok, message} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{"to" => "front", "subject" => "Hi"})

      %{
        shared: shared,
        message: message,
        reader: scope_for(reader),
        writer: scope_for(writer),
        stranger: scope_for(user_fixture()),
        no_inbox: scope_for(reader, [])
      }
    end

    test "reading state needs read: a stranger or a scope without inbox is refused", ctx do
      for fun <- [&Messages.mark_seen/3, &Messages.mark_unseen/3, &Messages.toggle_star/3] do
        assert {:error, :mailbox_access_denied} = fun.(ctx.stranger, ctx.shared, ctx.message.uuid)
        assert {:error, :forbidden} = fun.(ctx.no_inbox, ctx.shared, ctx.message.uuid)
        assert {:error, :forbidden} = fun.(Scope.for_user(nil), ctx.shared, ctx.message.uuid)
        assert {:ok, _} = fun.(ctx.reader, ctx.shared, ctx.message.uuid)
      end
    end

    test "someone else's personal mailbox is refused", ctx do
      {:ok, sent} =
        Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
          "to" => ctx.bob.email,
          "subject" => "x"
        })

      assert {:error, :mailbox_access_denied} =
               Messages.mark_seen(ctx.alice_scope, ctx.bob_mb, sent.uuid)

      assert {:error, :mailbox_access_denied} =
               Messages.purge(ctx.alice_scope, ctx.bob_mb, sent.uuid)
    end

    test "filing needs write: a read grantee is refused", ctx do
      assert {:error, :mailbox_access_denied} =
               Messages.move_to_folder(ctx.reader, ctx.shared, ctx.message.uuid, "trash")

      assert {:error, :mailbox_access_denied} =
               Messages.purge(ctx.reader, ctx.shared, ctx.message.uuid)

      assert {:error, :forbidden} =
               Messages.move_to_folder(
                 scope_for(ctx.carol, []),
                 ctx.shared,
                 ctx.message.uuid,
                 "trash"
               )

      assert [_] = Messages.list_folder(ctx.shared.uuid, "inbox")

      assert {:ok, _} =
               Messages.move_to_folder(ctx.writer, ctx.shared, ctx.message.uuid, "archive")

      assert :ok = Messages.purge(ctx.writer, ctx.shared, ctx.message.uuid)
    end

    test "a draft is deleted only with write on its mailbox", ctx do
      {:ok, draft} = Messages.save_draft(ctx.writer, ctx.shared, %{"subject" => "Team draft"})

      assert {:error, :mailbox_access_denied} =
               Messages.delete_draft(ctx.reader, ctx.shared, draft.uuid)

      assert {:error, :forbidden} = Messages.delete_draft(ctx.no_inbox, ctx.shared, draft.uuid)
      assert [_] = Messages.list_folder(ctx.shared.uuid, "drafts")
      assert :ok = Messages.delete_draft(ctx.writer, ctx.shared, draft.uuid)
    end

    test "a draft can't be saved by a read grantee or without inbox", ctx do
      assert {:error, :mailbox_access_denied} =
               Messages.save_draft(ctx.reader, ctx.shared, %{"subject" => "x"})

      assert {:error, :forbidden} =
               Messages.save_draft(ctx.no_inbox, ctx.shared, %{"subject" => "x"})
    end

    test "a malformed message uuid is not found, not a crash", ctx do
      assert {:error, :message_not_found} = Messages.mark_seen(ctx.reader, ctx.shared, "nope")
    end
  end

  describe "listing" do
    setup ctx do
      for n <- 1..3 do
        {:ok, _} =
          Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
            "to" => ctx.bob.email,
            "subject" => "Message #{n}",
            "body" => "Body of number #{n}"
          })
      end

      ctx
    end

    test "counts match the listing", ctx do
      assert Messages.count_folder(ctx.bob_mb.uuid, "inbox") == 3
      assert length(Messages.list_folder(ctx.bob_mb.uuid, "inbox")) == 3
    end

    test "search matches subject and body", ctx do
      assert length(Messages.list_folder(ctx.bob_mb.uuid, "inbox", search: "Message 2")) == 1
      assert length(Messages.list_folder(ctx.bob_mb.uuid, "inbox", search: "number 3")) == 1
      assert length(Messages.list_folder(ctx.bob_mb.uuid, "inbox", search: "Body of")) == 3
      assert Messages.list_folder(ctx.bob_mb.uuid, "inbox", search: "nothing here") == []
    end

    test "a blank search term is ignored rather than matching nothing", ctx do
      assert length(Messages.list_folder(ctx.bob_mb.uuid, "inbox", search: "   ")) == 3
    end

    test "unseen_only filters read messages out", ctx do
      [%{message: first} | _] = Messages.list_folder(ctx.bob_mb.uuid, "inbox")
      {:ok, _} = Messages.mark_seen(ctx.bob_scope, ctx.bob_mb, first.uuid)

      assert length(Messages.list_folder(ctx.bob_mb.uuid, "inbox", unseen_only: true)) == 2
    end

    test "limit and offset paginate", ctx do
      page1 = Messages.list_folder(ctx.bob_mb.uuid, "inbox", limit: 2, offset: 0)
      page2 = Messages.list_folder(ctx.bob_mb.uuid, "inbox", limit: 2, offset: 2)

      assert length(page1) == 2
      assert length(page2) == 1
      assert Enum.map(page1, & &1.message.uuid) != Enum.map(page2, & &1.message.uuid)
    end
  end

  defp sent_activities(message_uuid) do
    from(a in "phoenix_kit_activities",
      where:
        a.action == "inbox.message_sent" and a.resource_uuid == type(^message_uuid, :binary_id),
      select: %{
        actor_uuid: type(a.actor_uuid, :binary_id),
        target_uuid: type(a.target_uuid, :binary_id),
        permanent: a.permanent,
        metadata: a.metadata
      }
    )
    |> Repo.all()
  end

  defp received_targets(message_uuid) do
    from(a in "phoenix_kit_activities",
      where:
        a.action == "inbox.message_received" and
          a.resource_uuid == type(^message_uuid, :binary_id),
      select: type(a.target_uuid, :binary_id)
    )
    |> Repo.all()
    |> Enum.sort()
  end
end
