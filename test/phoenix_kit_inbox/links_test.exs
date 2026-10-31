defmodule PhoenixKitInbox.LinksTest do
  @moduledoc """
  Links between messages and objects of the host: written when a message is
  sent (from the host, the conversation, the subject), changed by people, and
  announced to whoever watches the object.

  Not async: resolvers are configured through the application environment.
  """

  use PhoenixKitInbox.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitInbox.Links
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Schemas.Link
  alias PhoenixKitInbox.Test.OrderResolver
  alias PhoenixKitInbox.Test.RaisingResolver

  @order %{kind: "order", ref: "o-1"}

  setup do
    enable_inbox!()
    alice = user_fixture()
    bob = user_fixture()
    carol = user_fixture()
    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)
    {:ok, _carol_mb} = Mailboxes.ensure_user_mailbox(carol)

    for key <- [:link_resolvers, :test_link_refs, :test_resolver_failure] do
      saved = Application.fetch_env(:phoenix_kit_inbox, key)

      on_exit(fn ->
        case saved do
          {:ok, value} -> Application.put_env(:phoenix_kit_inbox, key, value)
          :error -> Application.delete_env(:phoenix_kit_inbox, key)
        end
      end)
    end

    %{
      alice: alice,
      bob: bob,
      carol: carol,
      alice_mb: alice_mb,
      bob_mb: bob_mb,
      alice_scope: scope_for(alice),
      bob_scope: scope_for(bob),
      carol_scope: scope_for(carol)
    }
  end

  defp resolvers(modules, refs) do
    Application.put_env(:phoenix_kit_inbox, :link_resolvers, modules)
    Application.put_env(:phoenix_kit_inbox, :test_link_refs, refs)
  end

  defp send_to(scope, mailbox, to, attrs \\ %{}, opts \\ []) do
    attrs = Map.merge(%{"to" => to.email, "subject" => "Hello", "body" => "Body"}, attrs)
    {:ok, message} = Messages.send_message(scope, mailbox, attrs, opts)
    message
  end

  defp reply_to(scope, mailbox, to, parent, opts \\ []) do
    send_to(scope, mailbox, to, %{"parent_uuid" => parent.uuid, "subject" => "Re: Hello"}, opts)
  end

  defp links_of(message),
    do: message.uuid |> Links.for_message() |> Enum.map(&{&1.kind, &1.ref, &1.source})

  defp allow(_scope, _kind, _ref), do: true

  describe "sending" do
    test "host links written with source host", ctx do
      message = send_to(ctx.alice_scope, ctx.alice_mb, ctx.bob, %{}, links: [@order])

      assert [%Link{kind: "order", ref: "o-1", source: "host", message_uuid: uuid}] =
               Links.for_message(message.uuid)

      assert uuid == message.uuid
    end

    test "host links are committed together with the message", ctx do
      message =
        send_to(ctx.alice_scope, ctx.alice_mb, ctx.bob, %{"subject" => "Committed"},
          links: [@order]
        )

      # Stored by the send's own transaction, so already there when it returns
      # and not dependent on the work done after the commit: a resolver that
      # fails changes nothing about it.
      resolvers([RaisingResolver], [])

      assert capture_log(fn ->
               other = send_to(ctx.alice_scope, ctx.alice_mb, ctx.bob, %{}, links: [@order])
               assert links_of(other) == [{"order", "o-1", "host"}]
             end) =~ "RaisingResolver"

      assert links_of(message) == [{"order", "o-1", "host"}]
    end

    test "a failing host link insert rolls the send back", ctx do
      # A rule the table did not have: the one link below cannot be stored.
      # DDL is transactional, so the sandbox takes it away again.
      Repo.query!(
        "ALTER TABLE phoenix_kit_inbox_message_links ADD CONSTRAINT links_test_no_boom CHECK (ref <> 'boom')"
      )

      :ok = Links.subscribe("order", "boom")

      capture_log(fn ->
        assert {:error, :links_failed} =
                 Messages.send_message(
                   ctx.alice_scope,
                   ctx.alice_mb,
                   %{"to" => ctx.bob.email, "subject" => "Rolled back", "body" => "Body"},
                   links: [@order, %{kind: "order", ref: "boom"}]
                 )
      end)

      # No message, no delivery, no link of the other entry, no announcement.
      assert Messages.list_folder(ctx.alice_mb.uuid, "sent") == []
      assert Messages.list_folder(ctx.bob_mb.uuid, "inbox") == []

      assert Repo.aggregate(
               from(m in PhoenixKitInbox.Schemas.Message, where: m.subject == "Rolled back"),
               :count
             ) == 0

      assert Repo.aggregate(Link, :count) == 0
      refute_received {:inbox_message_linked, _}
    end

    test "reply inherits the thread's links", ctx do
      root = send_to(ctx.alice_scope, ctx.alice_mb, ctx.bob, %{}, links: [@order])
      reply = reply_to(ctx.bob_scope, ctx.bob_mb, ctx.alice, root)

      assert links_of(reply) == [{"order", "o-1", "thread"}]
      # The root keeps what it was given.
      assert links_of(root) == [{"order", "o-1", "host"}]

      # An unrelated message starts clean.
      other = send_to(ctx.alice_scope, ctx.alice_mb, ctx.bob)
      assert links_of(other) == []
    end

    test "a host link on a reply wins over the inherited one", ctx do
      root = send_to(ctx.alice_scope, ctx.alice_mb, ctx.bob, %{}, links: [@order])
      reply = reply_to(ctx.bob_scope, ctx.bob_mb, ctx.alice, root, links: [@order])

      assert links_of(reply) == [{"order", "o-1", "host"}]
    end

    test "subject resolver links only when exists?", ctx do
      resolvers([OrderResolver], ["64"])

      message =
        send_to(ctx.alice_scope, ctx.alice_mb, ctx.bob, %{"subject" => "Offer #64 and #65"})

      assert links_of(message) == [{"order", "64", "subject"}]
    end

    test "resolver that raises does not block the message", ctx do
      resolvers([RaisingResolver, OrderResolver], ["64"])

      for failure <- [:raise, :throw, :exit] do
        Application.put_env(:phoenix_kit_inbox, :test_resolver_failure, failure)

        log =
          capture_log(fn ->
            message =
              send_to(ctx.alice_scope, ctx.alice_mb, ctx.bob, %{"subject" => "Offer #64"})

            assert message.status == "sent"
            assert {:ok, _} = Messages.fetch_for_mailbox(ctx.bob_mb.uuid, message.uuid)
            # The resolver after the broken one still ran.
            assert links_of(message) == [{"order", "64", "subject"}]
          end)

        assert log =~ "RaisingResolver"
      end
    end

    test "links in attrs are ignored; links in opts are used", ctx do
      forged = %{"links" => [%{"kind" => "order", "ref" => "forged"}]}
      forged_atoms = %{links: [%{kind: "order", ref: "forged"}]}

      for attrs <- [forged, forged_atoms] do
        message = send_to(ctx.alice_scope, ctx.alice_mb, ctx.bob, attrs)
        assert links_of(message) == []
      end

      message =
        send_to(ctx.alice_scope, ctx.alice_mb, ctx.bob, forged, links: [@order])

      assert links_of(message) == [{"order", "o-1", "host"}]
    end

    test "malformed host links are dropped, the message is sent", ctx do
      bad = [
        %{kind: "", ref: "x"},
        %{kind: "order", ref: String.duplicate("r", 256)},
        %{kind: String.duplicate("k", 65), ref: "x"},
        %{kind: "order"},
        "order",
        nil
      ]

      message = send_to(ctx.alice_scope, ctx.alice_mb, ctx.bob, %{}, links: [@order | bad])
      assert links_of(message) == [{"order", "o-1", "host"}]
    end

    test "dropped host links are logged by kind of fault, without the ref", ctx do
      log =
        capture_log(fn ->
          send_to(ctx.alice_scope, ctx.alice_mb, ctx.bob, %{},
            links: [@order, %{kind: "order", ref: "secret-ref-" <> String.duplicate("r", 300)}]
          )
        end)

      assert log =~ "1 host link"
      refute log =~ "secret-ref"
    end

    test "lengths are counted in code points, as the database counts them", ctx do
      # 64 graphemes, 128 code points: too long for the column.
      decomposed = String.duplicate("e\u0301", 64)
      assert String.length(decomposed) == 64

      message =
        send_to(ctx.alice_scope, ctx.alice_mb, ctx.bob, %{},
          links: [
            @order,
            %{kind: decomposed, ref: "x"},
            %{kind: "order", ref: decomposed <> decomposed <> decomposed}
          ]
        )

      assert links_of(message) == [{"order", "o-1", "host"}]

      exactly = String.duplicate("k", 64)

      message =
        send_to(ctx.alice_scope, ctx.alice_mb, ctx.bob, %{}, links: [%{kind: exactly, ref: "x"}])

      assert links_of(message) == [{exactly, "x", "host"}]
    end

    test "a NUL byte in kind or ref is dropped", ctx do
      message =
        send_to(ctx.alice_scope, ctx.alice_mb, ctx.bob, %{},
          links: [@order, %{kind: "or\0der", ref: "x"}, %{kind: "order", ref: "x\0y"}]
        )

      assert links_of(message) == [{"order", "o-1", "host"}]
    end

    test "a draft of the conversation gives nothing to inherit", ctx do
      root = send_to(ctx.alice_scope, ctx.alice_mb, ctx.bob, %{}, links: [@order])

      {:ok, draft} =
        Messages.save_draft(ctx.bob_scope, ctx.bob_mb, %{
          "to" => ctx.alice.email,
          "subject" => "Re: Hello",
          "parent_uuid" => root.uuid
        })

      Links.record(draft.uuid, [%{kind: "order", ref: "from-draft"}], "host")

      reply = reply_to(ctx.bob_scope, ctx.bob_mb, ctx.alice, root)
      assert links_of(reply) == [{"order", "o-1", "thread"}]
    end
  end

  describe "record/3" do
    test "source conflict keeps the more explicit source", ctx do
      message = send_to(ctx.alice_scope, ctx.alice_mb, ctx.bob)
      record = fn source, opts -> Links.record(message.uuid, [@order], source, opts) end

      record.("subject", [])
      assert links_of(message) == [{"order", "o-1", "subject"}]

      record.("thread", [])
      assert links_of(message) == [{"order", "o-1", "thread"}]

      record.("manual", linked_by: ctx.alice.uuid)
      assert [%Link{source: "manual", linked_by_user_uuid: by}] = Links.for_message(message.uuid)
      assert by == ctx.alice.uuid

      # Weaker sources change nothing, not even who linked it.
      record.("thread", [])
      record.("subject", [])
      record.("manual", linked_by: ctx.bob.uuid)
      assert [%Link{source: "manual", linked_by_user_uuid: ^by}] = Links.for_message(message.uuid)

      record.("host", [])
      assert links_of(message) == [{"order", "o-1", "host"}]

      record.("manual", linked_by: ctx.alice.uuid)
      record.("subject", [])
      assert links_of(message) == [{"order", "o-1", "host"}]
    end

    test "duplicates in one call are one row", ctx do
      message = send_to(ctx.alice_scope, ctx.alice_mb, ctx.bob)
      assert :ok = Links.record(message.uuid, [@order, @order], "host")
      assert [_one] = Links.for_message(message.uuid)
    end
  end

  describe "link/5 and unlink/5" do
    setup ctx do
      root = send_to(ctx.alice_scope, ctx.alice_mb, ctx.bob)
      reply = reply_to(ctx.bob_scope, ctx.bob_mb, ctx.alice, root)
      %{root: root, reply: reply}
    end

    test "link on a root links all current thread messages", ctx do
      assert {:ok, %Link{source: "manual", message_uuid: uuid} = row} =
               Links.link(ctx.alice_scope, ctx.root.uuid, "order", "o-1", can_link?: &allow/3)

      assert uuid == ctx.root.uuid
      assert row.linked_by_user_uuid == ctx.alice.uuid
      assert links_of(ctx.root) == [{"order", "o-1", "manual"}]
      assert links_of(ctx.reply) == [{"order", "o-1", "manual"}]

      # A later reply inherits it.
      later = reply_to(ctx.alice_scope, ctx.alice_mb, ctx.bob, ctx.reply)
      assert links_of(later) == [{"order", "o-1", "thread"}]
    end

    test "linking a root leaves the drafts of its conversation alone", ctx do
      {:ok, draft} =
        Messages.save_draft(ctx.bob_scope, ctx.bob_mb, %{
          "to" => ctx.alice.email,
          "subject" => "Re: Hello",
          "parent_uuid" => ctx.root.uuid
        })

      {:ok, _} =
        Links.link(ctx.alice_scope, ctx.root.uuid, "order", "o-1", can_link?: &allow/3)

      assert Links.for_message(draft.uuid) == []
      assert links_of(ctx.reply) == [{"order", "o-1", "manual"}]
    end

    test "link keeps a stronger source the message already had", ctx do
      Links.record(ctx.root.uuid, [@order], "host")

      assert {:ok, %Link{source: "host"}} =
               Links.link(ctx.alice_scope, ctx.root.uuid, "order", "o-1", can_link?: &allow/3)

      assert links_of(ctx.reply) == [{"order", "o-1", "manual"}]
    end

    test "unlink leaves other messages of the thread", ctx do
      {:ok, _} = Links.link(ctx.alice_scope, ctx.root.uuid, "order", "o-1", can_link?: &allow/3)

      assert :ok =
               Links.unlink(ctx.alice_scope, ctx.reply.uuid, "order", "o-1", can_link?: &allow/3)

      assert links_of(ctx.reply) == []
      assert links_of(ctx.root) == [{"order", "o-1", "manual"}]

      # Nothing to unlink is not an error.
      assert :ok =
               Links.unlink(ctx.alice_scope, ctx.reply.uuid, "order", "o-1", can_link?: &allow/3)
    end

    test "link refuses without can_link?", ctx do
      assert {:error, :forbidden} = Links.link(ctx.alice_scope, ctx.root.uuid, "order", "o-1")

      assert {:error, :forbidden} =
               Links.link(ctx.alice_scope, ctx.root.uuid, "order", "o-1",
                 can_link?: fn _, _, _ -> false end
               )

      assert {:error, :forbidden} = Links.unlink(ctx.alice_scope, ctx.root.uuid, "order", "o-1")

      # The host is asked with the scope, the kind and the ref.
      test_pid = self()

      Links.link(ctx.alice_scope, ctx.root.uuid, "order", "o-1",
        can_link?: fn scope, kind, ref ->
          send(test_pid, {:asked, scope.user.uuid, kind, ref})
          false
        end
      )

      alice_uuid = ctx.alice.uuid
      assert_received {:asked, ^alice_uuid, "order", "o-1"}
      assert links_of(ctx.root) == []
    end

    test "unlink refuses without can_link?", ctx do
      {:ok, _} = Links.link(ctx.alice_scope, ctx.root.uuid, "order", "o-1", can_link?: &allow/3)

      assert {:error, :forbidden} = Links.unlink(ctx.alice_scope, ctx.root.uuid, "order", "o-1")
      assert links_of(ctx.root) == [{"order", "o-1", "manual"}]
    end

    test "link refuses a message the viewer cannot read", ctx do
      opts = [can_link?: &allow/3]

      assert {:error, :message_not_found} =
               Links.link(ctx.carol_scope, ctx.root.uuid, "order", "o-1", opts)

      assert {:error, :message_not_found} =
               Links.unlink(ctx.carol_scope, ctx.root.uuid, "order", "o-1", opts)

      assert {:error, :message_not_found} =
               Links.link(ctx.alice_scope, Ecto.UUID.generate(), "order", "o-1", opts)

      assert {:error, :message_not_found} =
               Links.link(ctx.alice_scope, "not-a-uuid", "order", "o-1", opts)

      # Not even a user who lost the right to use the inbox.
      assert {:error, :message_not_found} =
               Links.link(scope_for(ctx.alice, []), ctx.root.uuid, "order", "o-1", opts)

      assert links_of(ctx.root) == []
    end

    test "link refuses a kind longer than the column in code points, and a NUL", ctx do
      long = String.duplicate("e\u0301", 64)

      for {kind, ref} <- [{long, "x"}, {"order", long <> long <> long}, {"or\0der", "x"}] do
        assert {:error, :invalid_link} =
                 Links.link(ctx.alice_scope, ctx.root.uuid, kind, ref, can_link?: &allow/3)
      end
    end

    test "link refuses a malformed kind or ref", ctx do
      opts = [can_link?: &allow/3]

      assert {:error, :invalid_link} = Links.link(ctx.alice_scope, ctx.root.uuid, "", "o-1", opts)

      assert {:error, :invalid_link} =
               Links.link(
                 ctx.alice_scope,
                 ctx.root.uuid,
                 "order",
                 String.duplicate("r", 256),
                 opts
               )

      assert {:error, :invalid_link} =
               Links.link(ctx.alice_scope, ctx.root.uuid, "order", nil, opts)
    end
  end

  describe "subscribe/2" do
    test "subscribers get inbox_message_linked", ctx do
      assert :ok = Links.subscribe("order", "o-1")
      assert :ok = Links.subscribe("order", "a:b/c d")

      message = send_to(ctx.alice_scope, ctx.alice_mb, ctx.bob, %{}, links: [@order])
      uuid = message.uuid
      assert_receive {:inbox_message_linked, ^uuid}

      # From the conversation and the subject, too.
      reply = reply_to(ctx.bob_scope, ctx.bob_mb, ctx.alice, message)
      reply_uuid = reply.uuid
      assert_receive {:inbox_message_linked, ^reply_uuid}

      # By a person: once per message of the conversation, and on unlink.
      other = send_to(ctx.alice_scope, ctx.alice_mb, ctx.bob)
      other_uuid = other.uuid
      refute_received {:inbox_message_linked, ^other_uuid}

      {:ok, _} =
        Links.link(ctx.alice_scope, other.uuid, "order", "a:b/c d", can_link?: &allow/3)

      assert_receive {:inbox_message_linked, ^other_uuid}

      :ok = Links.unlink(ctx.alice_scope, other.uuid, "order", "a:b/c d", can_link?: &allow/3)
      assert_receive {:inbox_message_linked, ^other_uuid}
    end

    test "unsubscribe stops the events", ctx do
      :ok = Links.subscribe("order", "o-1")
      assert :ok = Links.unsubscribe("order", "o-1")

      send_to(ctx.alice_scope, ctx.alice_mb, ctx.bob, %{}, links: [@order])
      refute_receive {:inbox_message_linked, _}, 100
    end

    test "subscribers of another object hear nothing", ctx do
      :ok = Links.subscribe("order", "o-2")
      send_to(ctx.alice_scope, ctx.alice_mb, ctx.bob, %{}, links: [@order])

      refute_receive {:inbox_message_linked, _}, 100
    end

    test "the subject match announces too", ctx do
      resolvers([OrderResolver], ["64"])
      :ok = Links.subscribe("order", "64")

      message = send_to(ctx.alice_scope, ctx.alice_mb, ctx.bob, %{"subject" => "Offer #64"})
      uuid = message.uuid
      assert_receive {:inbox_message_linked, ^uuid}
    end
  end

  describe "Messages.fetch_for_scope/2" do
    test "reads through any mailbox of the person, nobody else's", ctx do
      message = send_to(ctx.alice_scope, ctx.alice_mb, ctx.bob)

      assert {:ok, %{message: %{uuid: uuid}, delivery: %{mailbox_uuid: sender_box}}} =
               Messages.fetch_for_scope(ctx.alice_scope, message.uuid)

      assert uuid == message.uuid
      assert sender_box == ctx.alice_mb.uuid

      assert {:ok, %{delivery: %{mailbox_uuid: box}}} =
               Messages.fetch_for_scope(ctx.bob_scope, message.uuid)

      assert box == ctx.bob_mb.uuid

      assert {:error, :message_not_found} =
               Messages.fetch_for_scope(ctx.carol_scope, message.uuid)
    end
  end
end
