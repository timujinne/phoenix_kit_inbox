defmodule PhoenixKitInbox.ObjectMailTest do
  @moduledoc """
  The mail of an object of the host as one person may read it: only what the
  mailboxes they can open hold, never anyone's personal mail, never a copy in
  the trash, spam or archive, never a draft — whatever the links say.
  """

  use PhoenixKitInbox.DataCase, async: false

  alias PhoenixKitInbox.Links
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.ObjectMail
  alias PhoenixKitInbox.Schemas.Delivery
  alias PhoenixKitInbox.Schemas.ExternalRecipient
  alias PhoenixKitInbox.Schemas.Message

  @order %{kind: "order", ref: "o-1"}
  @other %{kind: "order", ref: "o-2"}

  setup do
    enable_inbox!()
    admin = user_fixture()
    alice = user_fixture()
    bob = user_fixture()
    carol = user_fixture()
    dave = user_fixture()

    mailboxes =
      for user <- [alice, bob, carol, dave], into: %{} do
        {:ok, mailbox} = Mailboxes.ensure_user_mailbox(user)
        {user.uuid, mailbox}
      end

    desk = shared_mailbox_fixture(admin, %{name: "Desk", address: "desk@company.test"})
    grant_fixture(desk, alice, "read")

    %{
      alice: alice,
      bob: bob,
      carol: carol,
      dave: dave,
      alice_mb: mailboxes[alice.uuid],
      bob_mb: mailboxes[bob.uuid],
      carol_mb: mailboxes[carol.uuid],
      dave_mb: mailboxes[dave.uuid],
      desk: desk,
      alice_scope: scope_for(alice),
      bob_scope: scope_for(bob),
      carol_scope: scope_for(carol),
      dave_scope: scope_for(dave)
    }
  end

  # `from` is :alice, :bob, ... ; `to` a recipient string.
  defp mail(ctx, from, to, attrs), do: mail(ctx, from, to, attrs, [])

  defp mail(ctx, from, to, attrs, opts) do
    scope = Map.fetch!(ctx, :"#{from}_scope")
    mailbox = Map.fetch!(ctx, :"#{from}_mb")

    {:ok, message} =
      Messages.send_message(
        scope,
        mailbox,
        Map.merge(%{"to" => to, "subject" => "Subject", "body" => "Body"}, attrs),
        opts
      )

    message
  end

  defp handle(user), do: "@" <> user.username

  defp threads(scope, filter \\ [@order], opts \\ []),
    do: ObjectMail.list_threads(scope, filter, opts)

  defp uuids(threads), do: threads |> Enum.flat_map(& &1.messages) |> Enum.map(&entry_uuid/1)
  defp entry_uuid(entry), do: entry.message.uuid

  defp move_copy!(message, mailbox, folder) do
    {1, _} =
      Repo.update_all(
        from(d in Delivery,
          where: d.message_uuid == ^message.uuid and d.mailbox_uuid == ^mailbox.uuid
        ),
        set: [folder: folder]
      )
  end

  describe "list_threads/3" do
    test "other user's personal mailbox letters never returned", ctx do
      between_others = mail(ctx, :bob, handle(ctx.carol), %{}, links: [@order])
      to_alice = mail(ctx, :bob, handle(ctx.alice), %{}, links: [@order])

      assert uuids(threads(ctx.alice_scope)) == [to_alice.uuid]
      assert uuids(threads(ctx.carol_scope)) == [between_others.uuid]
      assert threads(ctx.dave_scope) == []

      # Not by any selection of the filter, the folder or the paging either.
      for folder <- [:all, :inbox, :sent] do
        refute between_others.uuid in uuids(threads(ctx.alice_scope, [@order], folder: folder))
      end

      refute between_others.uuid in uuids(threads(ctx.alice_scope, [@order, @other], limit: 100))
    end

    test "a link does not widen who may read", ctx do
      secret = mail(ctx, :bob, handle(ctx.carol), %{}, links: [@order])

      # Alice links her own letter to the same object: still not Bob's.
      mine = mail(ctx, :alice, handle(ctx.dave), %{}, links: [@order])

      assert uuids(threads(ctx.alice_scope)) == [mine.uuid]
      refute secret.uuid in uuids(threads(ctx.alice_scope))
    end

    test "shared mailbox letters visible with a grant", ctx do
      to_desk = mail(ctx, :bob, ctx.desk.address, %{}, links: [@order])

      assert uuids(threads(ctx.alice_scope)) == [to_desk.uuid]
      # Carol has no grant on the desk.
      assert threads(ctx.carol_scope) == []
      # The sender reads her own copy.
      assert uuids(threads(ctx.bob_scope)) == [to_desk.uuid]
    end

    test "bcc hidden in a reader's projection", ctx do
      message =
        mail(ctx, :bob, handle(ctx.alice), %{"bcc" => handle(ctx.carol)}, links: [@order])

      [%{messages: [seen_by_alice]}] = threads(ctx.alice_scope)
      [%{messages: [seen_by_bob]}] = threads(ctx.bob_scope)
      [%{messages: [seen_by_carol]}] = threads(ctx.carol_scope)

      roles = fn entry ->
        entry.message
        |> Messages.recipient_snapshot(entry.viewer_mailbox_uuid)
        |> Enum.map(& &1["role"])
      end

      assert roles.(seen_by_alice) == ["to"]
      assert Enum.sort(roles.(seen_by_bob)) == ["bcc", "to"]
      # The Bcc recipient sees their own entry and not anyone else's.
      assert Enum.sort(roles.(seen_by_carol)) == ["bcc", "to"]
      assert seen_by_alice.message.uuid == message.uuid

      # Nothing of the others' Bcc is anywhere in what the reader got.
      refute inspect(seen_by_alice.message.metadata) =~ ctx.carol_mb.uuid
    end

    test "external recipients and identity shown per viewer mailbox", ctx do
      message = mail(ctx, :bob, handle(ctx.alice), %{}, links: [@order])

      Repo.update_all(
        from(m in Message, where: m.uuid == ^message.uuid),
        set: [
          metadata:
            Map.put(message.metadata, "identity", %{
              "uuid" => Ecto.UUID.generate(),
              "integration_uuid" => Ecto.UUID.generate(),
              "from_address" => "desk@company.test"
            })
        ]
      )

      for {role, address} <- [{"to", "client@example.com"}, {"bcc", "hidden@example.com"}] do
        Repo.insert!(%ExternalRecipient{
          message_uuid: message.uuid,
          role: role,
          address: address,
          status: "sent"
        })
      end

      [%{messages: [for_alice]}] = threads(ctx.alice_scope)
      [%{messages: [for_bob]}] = threads(ctx.bob_scope)

      assert Enum.map(for_alice.external, & &1.address) == ["client@example.com"]
      refute Map.has_key?(for_alice.message.metadata, "identity")

      assert Enum.map(for_bob.external, & &1.address) == [
               "client@example.com",
               "hidden@example.com"
             ]

      assert for_bob.message.metadata["identity"]["from_address"] == "desk@company.test"
    end

    test "html_body never reaches the reader", ctx do
      message = mail(ctx, :bob, handle(ctx.alice), %{}, links: [@order])

      Repo.update_all(
        from(m in Message, where: m.uuid == ^message.uuid),
        set: [metadata: Map.put(message.metadata, "html_body", "<b>brand</b>")]
      )

      for scope <- [ctx.alice_scope, ctx.bob_scope] do
        [%{messages: [entry]}] = threads(scope)
        refute Map.has_key?(entry.message.metadata, "html_body")
      end
    end

    test "trashed, spam, archived, draft copies excluded", ctx do
      kept = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Kept"}, links: [@order])

      for folder <- ~w(trash spam archive) do
        message = mail(ctx, :bob, handle(ctx.alice), %{"subject" => folder}, links: [@order])
        move_copy!(message, ctx.alice_mb, folder)
        # Bob's own copy is in the Sent folder: the letter is Alice's to hide
        # only from her reading, and Alice is not Bob.
        refute message.uuid in uuids(threads(ctx.alice_scope))
      end

      {:ok, draft} =
        Messages.save_draft(ctx.alice_scope, ctx.alice_mb, %{
          "to" => handle(ctx.bob),
          "subject" => "Draft"
        })

      Links.record(draft.uuid, [@order], "host")

      assert uuids(threads(ctx.alice_scope)) == [kept.uuid]

      # A deleted copy (tombstone) is not visible either.
      deleted = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Deleted"}, links: [@order])

      Repo.update_all(
        from(d in Delivery,
          where: d.message_uuid == ^deleted.uuid and d.mailbox_uuid == ^ctx.alice_mb.uuid
        ),
        set: [status: "deleted"]
      )

      assert uuids(threads(ctx.alice_scope)) == [kept.uuid]
    end

    test "thread appears when any visible message is linked; shows all visible messages", ctx do
      root = mail(ctx, :alice, handle(ctx.bob), %{"subject" => "Root"})

      reply =
        mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Re: Root", "parent_uuid" => root.uuid},
          links: [@order]
        )

      # A message of the conversation Alice is not party to.
      aside =
        mail(ctx, :bob, handle(ctx.carol), %{"subject" => "Aside", "parent_uuid" => root.uuid})

      assert aside.thread_uuid == root.thread_uuid

      assert [%{thread_uuid: thread, messages: entries}] = threads(ctx.alice_scope)
      assert thread == root.thread_uuid
      assert Enum.map(entries, & &1.message.uuid) == [root.uuid, reply.uuid]
      assert Enum.map(entries, & &1.message.parent_uuid) == [nil, root.uuid]
      assert Enum.map(entries, & &1.links) |> Enum.map(&length/1) == [0, 1]
      assert [%{source: "host", kind: "order", ref: "o-1"}] = Enum.at(entries, 1).links

      # Carol is party to one letter only (it inherited the link of the
      # conversation): she gets that letter, none of the others.
      assert [%{messages: [only]}] = threads(ctx.carol_scope)
      assert only.message.uuid == aside.uuid
      assert [%{source: "thread"}] = only.links
    end

    test "letter seen through two mailboxes appears once", ctx do
      message =
        mail(ctx, :bob, handle(ctx.alice), %{"cc" => ctx.desk.address}, links: [@order])

      assert [%{messages: [entry]}] = threads(ctx.alice_scope)
      assert entry.message.uuid == message.uuid
    end

    test "folder option filters inbox and sent", ctx do
      incoming = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "In"}, links: [@order])
      outgoing = mail(ctx, :alice, handle(ctx.bob), %{"subject" => "Out"}, links: [@order])

      assert Enum.sort(uuids(threads(ctx.alice_scope))) ==
               Enum.sort([incoming.uuid, outgoing.uuid])

      assert uuids(threads(ctx.alice_scope, [@order], folder: :inbox)) == [incoming.uuid]
      assert uuids(threads(ctx.alice_scope, [@order], folder: :sent)) == [outgoing.uuid]

      assert [%{messages: [%{direction: :inbox}]}] =
               threads(ctx.alice_scope, [@order], folder: :inbox)

      assert [%{messages: [%{direction: :sent}]}] =
               threads(ctx.alice_scope, [@order], folder: :sent)
    end

    test "scope without inbox gets []", ctx do
      mail(ctx, :bob, handle(ctx.alice), %{}, links: [@order])

      assert threads(scope_for(ctx.alice, [])) == []
      assert threads(nil) == []
      assert threads(ctx.alice_scope, []) == []
      assert threads(ctx.alice_scope, :nonsense) == []
    end

    test "empty after unlink", ctx do
      message = mail(ctx, :bob, handle(ctx.alice), %{}, links: [@order])
      assert [_] = threads(ctx.alice_scope)

      assert :ok =
               Links.unlink(ctx.alice_scope, message.uuid, "order", "o-1",
                 can_link?: fn _, _, _ -> true end
               )

      assert threads(ctx.alice_scope) == []
    end

    test "any element of the filter selects; others do not", ctx do
      first = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "A"}, links: [@order])
      second = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "B"}, links: [@other])
      _third = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "C"})

      assert uuids(threads(ctx.alice_scope, [@order])) == [first.uuid]

      assert Enum.sort(uuids(threads(ctx.alice_scope, [@order, @other]))) ==
               Enum.sort([first.uuid, second.uuid])

      # Only the links of the filter are reported.
      [%{messages: [entry]}] = threads(ctx.alice_scope, [@order])
      assert [%{ref: "o-1"}] = entry.links
    end

    test "limit and offset count threads, newest conversation first", ctx do
      old = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Old"}, links: [@order])

      reply =
        mail(ctx, :alice, handle(ctx.bob), %{"parent_uuid" => old.uuid, "subject" => "Re: Old"})

      new = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "New"}, links: [@order])

      stamp!(old, ~U[2026-01-01 10:00:00Z])
      stamp!(reply, ~U[2026-01-02 10:00:00Z])
      stamp!(new, ~U[2026-02-01 10:00:00Z])

      all = threads(ctx.alice_scope)
      assert Enum.map(all, & &1.thread_uuid) == [new.thread_uuid, old.thread_uuid]
      assert [%{last_at: %DateTime{}} | _] = all

      # Two messages in the older thread, one page of one thread.
      assert [%{thread_uuid: thread, messages: [_]}] =
               threads(ctx.alice_scope, [@order], limit: 1)

      assert thread == new.thread_uuid

      assert [%{thread_uuid: thread, messages: messages}] =
               threads(ctx.alice_scope, [@order], limit: 1, offset: 1)

      assert thread == old.thread_uuid
      assert length(messages) == 2
    end

    test "the number of queries does not grow with threads or mailboxes", ctx do
      count_queries = fn fun ->
        counter = :counters.new(1, [])
        id = {:query_counter, System.unique_integer()}

        :telemetry.attach(
          id,
          Repo.config()[:telemetry_prefix] ++ [:query],
          fn _event, _measurements, _meta, counter -> :counters.add(counter, 1, 1) end,
          counter
        )

        try do
          fun.()
        after
          :telemetry.detach(id)
        end

        :counters.get(counter, 1)
      end

      mail(ctx, :bob, handle(ctx.alice), %{}, links: [@order])
      few = count_queries.(fn -> threads(ctx.alice_scope) end)

      for n <- 1..6 do
        shared =
          shared_mailbox_fixture(ctx.carol, %{
            name: "Extra #{n}",
            address: "extra#{n}@company.test"
          })

        grant_fixture(shared, ctx.alice, "read")

        mail(ctx, :bob, shared.address, %{"subject" => "T#{n}"}, links: [@order])
      end

      many = count_queries.(fn -> threads(ctx.alice_scope) end)

      assert many == few
      assert length(threads(ctx.alice_scope)) > 3
    end
  end

  describe "link_candidates/2" do
    test "letters without any link, from the mailboxes the viewer may read", ctx do
      free = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Free"})
      linked = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Linked"}, links: [@order])
      _foreign = mail(ctx, :bob, handle(ctx.carol), %{"subject" => "Not Alice's"})
      to_desk = mail(ctx, :bob, ctx.desk.address, %{"subject" => "Desk"})

      uuids = ctx.alice_scope |> ObjectMail.link_candidates() |> Enum.map(&entry_uuid/1)

      assert Enum.sort(uuids) == Enum.sort([free.uuid, to_desk.uuid])
      refute linked.uuid in uuids
    end

    test "limit, and the same rules of visibility", ctx do
      for n <- 1..5, do: mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Quote #{n}"})

      assert length(ObjectMail.link_candidates(ctx.alice_scope, limit: 3)) == 3

      assert ObjectMail.link_candidates(scope_for(ctx.alice, [])) == []
      assert ObjectMail.link_candidates(nil) == []

      {:ok, draft} =
        Messages.save_draft(ctx.alice_scope, ctx.alice_mb, %{
          "to" => handle(ctx.bob),
          "subject" => "Draft"
        })

      refute draft.uuid in Enum.map(ObjectMail.link_candidates(ctx.alice_scope), &entry_uuid/1)
    end

    test "a letter seen through two mailboxes is offered once", ctx do
      mail(ctx, :bob, handle(ctx.alice), %{"cc" => ctx.desk.address})
      assert [_one] = ObjectMail.link_candidates(ctx.alice_scope)
    end
  end

  defp stamp!(message, datetime) do
    Repo.update_all(from(m in Message, where: m.uuid == ^message.uuid), set: [sent_at: datetime])
  end
end
