defmodule PhoenixKitInbox.SenderOptionsTest do
  @moduledoc """
  What `Messages.send_message/4` does with a sending identity, a Reply-To and
  a Markdown body: checks them, records them on the message, sends nothing
  outside the application.
  """

  use PhoenixKitInbox.DataCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Schemas.Message

  @external ["inbox", "inbox.send_external"]

  setup do
    enable_inbox!()
    admin = user_fixture()
    alice = user_fixture(%{first_name: "Alice", last_name: "Smith"})
    bob = user_fixture()
    desk = shared_mailbox_fixture(admin, %{name: "Desk", address: "desk@company.test"})
    grant_fixture(desk, alice, "write")
    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)
    system_smtp = mail_integration_fixture(:system, username: "noreply@company.test")
    # The role that sends externally; the common sender is opened to it.
    senders = grant_role!(alice, @external)

    {:ok, common} =
      Identities.create_shared(scope_for(admin, ["inbox", "inbox.manage_shared"]), %{
        "label" => "Common",
        "from_name" => "Company",
        "integration_uuid" => system_smtp
      })

    %{
      alice: alice,
      bob: bob,
      desk: desk,
      alice_mb: alice_mb,
      bob_mb: bob_mb,
      common: common,
      senders: senders,
      system_smtp: system_smtp
    }
  end

  defp send(ctx, scope, mailbox, extra) do
    Messages.send_message(
      scope,
      mailbox,
      Map.merge(%{"to" => "@" <> ctx.bob.username, "subject" => "Hi", "body" => "Text"}, extra)
    )
  end

  describe "identity_uuid" do
    test "a usable identity is recorded on the message", ctx do
      assert {:ok, message} =
               send(ctx, scope_for(ctx.alice, @external, [ctx.senders]), ctx.alice_mb, %{
                 "identity_uuid" => ctx.common.uuid
               })

      assert message.metadata["identity"] == %{
               "uuid" => ctx.common.uuid,
               "kind" => "shared",
               "integration_uuid" => ctx.system_smtp,
               "from_address" => "noreply@company.test",
               "from_name" => "Alice Smith | Company"
             }

      # Delivered internally like any message.
      assert [%{message: %{uuid: uuid}}] = Messages.list_folder(ctx.bob_mb.uuid, "inbox")
      assert uuid == message.uuid
    end

    test "only the sending mailbox sees the identity; recipients keep the Reply-To", ctx do
      {:ok, message} =
        send(ctx, scope_for(ctx.alice, @external, [ctx.senders]), ctx.alice_mb, %{
          "identity_uuid" => ctx.common.uuid,
          "reply_to" => ctx.alice.email
        })

      assert {:ok, %{message: sent}} = Messages.fetch_for_mailbox(ctx.alice_mb.uuid, message.uuid)
      assert sent.metadata["identity"]["integration_uuid"] == ctx.system_smtp

      assert {:ok, %{message: received}} =
               Messages.fetch_for_mailbox(ctx.bob_mb.uuid, message.uuid)

      refute Map.has_key?(received.metadata, "identity")
      assert received.metadata["reply_to"] == ctx.alice.email

      assert [%{message: listed}] = Messages.list_folder(ctx.bob_mb.uuid, "inbox")
      refute Map.has_key?(listed.metadata, "identity")

      assert [threaded] = Messages.list_thread(message.thread_uuid)
      refute Map.has_key?(threaded.metadata, "identity")
    end

    test "an identity the sender may not use refuses the send", ctx do
      assert {:error, {:identity_unusable, :forbidden}} =
               send(ctx, scope_for(ctx.alice), ctx.alice_mb, %{
                 "identity_uuid" => ctx.common.uuid
               })

      assert Repo.aggregate(Message, :count) == 0
    end

    test "an identity of another mailbox refuses the send", ctx do
      assert {:error, {:identity_unusable, :identity_not_for_mailbox}} =
               send(ctx, scope_for(ctx.alice, @external, [ctx.senders]), ctx.desk, %{
                 "identity_uuid" => ctx.common.uuid
               })
    end

    test "a broken identity refuses the send", ctx do
      :ok = Integrations.remove_connection(ctx.system_smtp, nil, owner: :system)

      assert {:error, {:identity_unusable, :broken}} =
               send(ctx, scope_for(ctx.alice, @external, [ctx.senders]), ctx.alice_mb, %{
                 "identity_uuid" => ctx.common.uuid
               })

      assert Repo.aggregate(Message, :count) == 0
    end

    test "an unknown identity refuses the send", ctx do
      assert {:error, {:identity_unusable, :not_found}} =
               send(ctx, scope_for(ctx.alice, @external, [ctx.senders]), ctx.alice_mb, %{
                 "identity_uuid" => Ecto.UUID.generate()
               })
    end

    test "a blank one is no identity", ctx do
      assert {:ok, message} =
               send(ctx, scope_for(ctx.alice), ctx.alice_mb, %{"identity_uuid" => ""})

      refute Map.has_key?(message.metadata, "identity")
    end

    test "the caller's metadata can't forge one", ctx do
      assert {:ok, message} =
               send(ctx, scope_for(ctx.alice), ctx.alice_mb, %{
                 "metadata" => %{
                   "identity" => %{"from_address" => "ceo@company.test"},
                   "reply_to" => "ceo@company.test",
                   "note" => "kept"
                 }
               })

      refute Map.has_key?(message.metadata, "identity")
      refute Map.has_key?(message.metadata, "reply_to")
      assert message.metadata["note"] == "kept"
    end
  end

  describe "reply_to" do
    test "one of the sender's addresses is recorded", ctx do
      assert {:ok, message} =
               send(ctx, scope_for(ctx.alice), ctx.alice_mb, %{"reply_to" => "Desk@company.test"})

      assert message.metadata["reply_to"] == "desk@company.test"
    end

    test "anything else refuses the send", ctx do
      for forged <- ["ceo@company.test", ctx.bob.email] do
        assert {:error, :reply_to_not_allowed} =
                 send(ctx, scope_for(ctx.alice), ctx.alice_mb, %{"reply_to" => forged})
      end

      assert Repo.aggregate(Message, :count) == 0
    end
  end

  describe "the three-argument form" do
    test "takes no identity and no Reply-To", ctx do
      for extra <- [%{"identity_uuid" => ctx.common.uuid}, %{"reply_to" => ctx.alice.email}] do
        assert {:error, :sender_options_need_scope} =
                 Messages.send_message(
                   ctx.alice_mb,
                   ctx.alice.uuid,
                   Map.merge(%{"to" => "@" <> ctx.bob.username, "subject" => "Hi"}, extra)
                 )
      end
    end
  end

  describe "drafts" do
    test "keep the chosen identity and Reply-To unchecked until the send", ctx do
      scope = scope_for(ctx.alice, @external, [ctx.senders])

      {:ok, draft} =
        Messages.save_draft(scope, ctx.alice_mb, %{
          "subject" => "Later",
          "identity_uuid" => ctx.common.uuid,
          "reply_to" => "nobody@elsewhere.test"
        })

      assert Messages.draft_sender(draft) == %{
               "identity_uuid" => ctx.common.uuid,
               "reply_to" => "nobody@elsewhere.test"
             }

      assert {:error, :reply_to_not_allowed} =
               send(ctx, scope, ctx.alice_mb, %{
                 "uuid" => draft.uuid,
                 "identity_uuid" => ctx.common.uuid,
                 "reply_to" => "nobody@elsewhere.test"
               })

      assert {:ok, sent} =
               send(ctx, scope, ctx.alice_mb, %{
                 "uuid" => draft.uuid,
                 "identity_uuid" => ctx.common.uuid,
                 "reply_to" => ctx.alice.email
               })

      refute Map.has_key?(sent.metadata, "draft_sender")
      assert sent.metadata["reply_to"] == ctx.alice.email
    end
  end

  describe "body_format" do
    test "markdown is a body format", ctx do
      assert {:ok, %Message{body_format: "markdown"}} =
               send(ctx, scope_for(ctx.alice), ctx.alice_mb, %{
                 "body" => "**Hi**",
                 "body_format" => "markdown"
               })
    end

    test "an unknown one is refused", ctx do
      assert {:error, %Ecto.Changeset{} = changeset} =
               send(ctx, scope_for(ctx.alice), ctx.alice_mb, %{"body_format" => "script"})

      assert %{body_format: [_ | _]} = errors_on(changeset)
    end
  end
end
