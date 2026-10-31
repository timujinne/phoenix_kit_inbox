defmodule PhoenixKitInbox.HostOptionsTest do
  @moduledoc """
  The server-side options a host gives `Messages.send_message/4` —
  `reply_to_trusted:`, `html_body:` — and the sender-name flag of a shared
  identity: what they write, what the external email and its retry use, and
  what a reader never sees.
  """

  use PhoenixKitInbox.DataCase, async: false

  alias PhoenixKitInbox.Attachments.Folders
  alias PhoenixKitInbox.External
  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Schemas.Message

  @external ["inbox", "inbox.send_external"]
  @brand "<html><body><h1>Brand</h1></body></html>"

  setup :outbound_setup

  setup do
    enable_inbox!()
    admin = user_fixture()
    alice = user_fixture(%{first_name: "Alice", last_name: "Smith"})
    bob = user_fixture()
    carol = user_fixture(%{first_name: "Carol", last_name: "Jones"})
    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)
    smtp = mail_integration_fixture(:system, username: "noreply@company.test")
    senders = grant_role!(alice, @external)
    grant_role!(carol, [], name: senders.name)
    manager = scope_for(admin, ["inbox", "inbox.manage_shared"])

    {:ok, common} =
      Identities.create_shared(manager, %{
        "label" => "Common",
        "from_name" => "Company",
        "integration_uuid" => smtp
      })

    desk = shared_mailbox_fixture(admin, %{name: "Desk", address: "desk@company.test"})
    grant_fixture(desk, alice, "write")
    grant_fixture(desk, carol, "write")

    {:ok, bound} =
      Identities.create_shared(manager, %{
        "label" => "Desk sender",
        "integration_uuid" => smtp,
        "mailbox_uuid" => desk.uuid
      })

    :ok = External.subscribe(alice_mb.uuid)
    :ok = External.subscribe(desk.uuid)

    %{
      manager: manager,
      alice: alice,
      bob: bob,
      carol: carol,
      alice_mb: alice_mb,
      bob_mb: bob_mb,
      common: common,
      desk: desk,
      bound: bound,
      alice_scope: scope_for(alice, @external, [senders]),
      carol_scope: scope_for(carol, @external, [senders])
    }
  end

  defp external_attrs(ctx, extra \\ %{}) do
    Map.merge(
      %{
        "to" => "client@example.com",
        "subject" => "Offer",
        "body" => "Plain words",
        "identity_uuid" => ctx.common.uuid
      },
      extra
    )
  end

  defp send_external(ctx, extra \\ %{}, opts \\ []) do
    ctx.alice_scope
    |> Messages.send_message(ctx.alice_mb, external_attrs(ctx, extra), opts)
    |> tap(fn
      {:ok, %Message{external_status: :pending} = message} -> await_external(message.uuid)
      _ -> :ok
    end)
  end

  defp send_from_desk(ctx, scope, opts \\ []) do
    attrs = external_attrs(ctx, %{"identity_uuid" => ctx.bound.uuid})

    scope
    |> Messages.send_message(ctx.desk, attrs, opts)
    |> tap(fn
      {:ok, %Message{external_status: :pending} = message} -> await_external(message.uuid)
      _ -> :ok
    end)
  end

  defp stored(message), do: Repo.get!(Message, message.uuid)

  defp message_count, do: Repo.aggregate(Message, :count)

  describe "reply_to_trusted" do
    test "reply_to_trusted accepted from opts", ctx do
      assert {:ok, message} =
               send_external(ctx, %{}, reply_to_trusted: "designer@elsewhere.example")

      assert stored(message).metadata["reply_to"] == "designer@elsewhere.example"
      assert_received {:outbound, email, _, _}
      assert email.reply_to == {"", "designer@elsewhere.example"}
    end

    test "reply_to outside options still refused from attrs", ctx do
      assert {:error, :reply_to_not_allowed} =
               send_external(ctx, %{"reply_to" => "designer@elsewhere.example"})

      # Neither a look-alike key in attrs nor a trusted option elsewhere
      # opens the form's door.
      assert {:error, :reply_to_not_allowed} =
               send_external(
                 ctx,
                 %{"reply_to" => "designer@elsewhere.example"},
                 reply_to_trusted: "other@elsewhere.example"
               )

      assert {:ok, message} =
               send_external(ctx, %{"reply_to_trusted" => "designer@elsewhere.example"})

      refute Map.has_key?(stored(message).metadata, "reply_to")
      assert message_count() == 1
    end

    test "a malformed trusted address is refused", ctx do
      for bad <- [
            "not an address",
            "a@b",
            "x@y.z\r\nBcc: spy@example.com",
            "a@b.c\0",
            <<?a, ?@, ?b, ?., 0xFF>>,
            42
          ] do
        assert {:error, :invalid_reply_to} = send_external(ctx, %{}, reply_to_trusted: bad)
      end

      assert message_count() == 0
    end

    test "nil, an empty string and no option mean none", ctx do
      for opts <- [[reply_to_trusted: nil], [reply_to_trusted: ""], []] do
        assert {:ok, message} = send_external(ctx, %{}, opts)
        refute Map.has_key?(stored(message).metadata, "reply_to")
      end
    end

    test "a retry keeps the trusted Reply-To", ctx do
      outbound_result({:error, :smtp_down})

      assert {:ok, message} =
               send_external(ctx, %{}, reply_to_trusted: "designer@elsewhere.example")

      assert_received {:outbound, _, _, _}
      emails_module_enabled!()
      email_log_fixture(%{"inbox_message_uuid" => message.uuid}, "failed")
      outbound_result({:ok, %{id: "ok"}})

      assert {:ok, :pending} =
               Messages.retry_external(ctx.alice_scope, ctx.alice_mb, message.uuid)

      await_external(message.uuid)
      assert_received {:outbound, retried, _, _}
      assert retried.reply_to == {"", "designer@elsewhere.example"}
    end
  end

  describe "html_body" do
    test "html_body in attrs metadata stripped", ctx do
      attrs = %{"metadata" => %{"html_body" => "<b>forged</b>", "kept" => "yes"}}

      {:ok, message} =
        Messages.send_message(
          ctx.alice_scope,
          ctx.alice_mb,
          Map.merge(%{"to" => "@#{ctx.bob.username}", "subject" => "Hi"}, attrs)
        )

      metadata = stored(message).metadata
      refute Map.has_key?(metadata, "html_body")
      assert metadata["kept"] == "yes"

      # The same through a draft that is later sent.
      {:ok, draft} =
        Messages.save_draft(ctx.alice_scope, ctx.alice_mb, %{
          "to" => "@#{ctx.bob.username}",
          "subject" => "Draft",
          "metadata" => %{"html_body" => "<b>forged</b>"}
        })

      {:ok, sent} =
        Messages.send_message(ctx.alice_scope, ctx.alice_mb, %{
          "uuid" => draft.uuid,
          "to" => "@#{ctx.bob.username}",
          "subject" => "Draft",
          "metadata" => %{"html_body" => "<b>forged</b>"}
        })

      refute Map.has_key?(stored(sent).metadata, "html_body")
    end

    test "atom keys in attrs metadata do not get round the server-only keys", ctx do
      forged = %{
        html_body: "<b>forged</b>",
        reply_to: "spy@elsewhere.example",
        identity: %{"from_name" => "Forged"},
        kept: "yes"
      }

      {:ok, message} =
        Messages.send_message(ctx.alice_scope, ctx.alice_mb, %{
          "to" => "@#{ctx.bob.username}",
          "subject" => "Hi",
          "metadata" => forged
        })

      metadata = stored(message).metadata
      refute Map.has_key?(metadata, "html_body")
      refute Map.has_key?(metadata, "reply_to")
      refute Map.has_key?(metadata, "identity")
      assert metadata["kept"] == "yes"

      # A draft keeps no forged copy of the folder key either.
      {:ok, draft} =
        Messages.save_draft(ctx.alice_scope, ctx.alice_mb, %{
          "to" => "@#{ctx.bob.username}",
          "subject" => "Draft",
          "metadata" => %{String.to_atom(Folders.folder_key()) => "elsewhere"}
        })

      refute Map.has_key?(stored(draft).metadata, Folders.folder_key())
    end

    test "html_body used in external email and kept for retry", ctx do
      outbound_result({:error, :smtp_down})
      assert {:ok, message} = send_external(ctx, %{}, html_body: @brand)

      assert_received {:outbound, first, _, _}
      assert first.html_body == @brand
      assert first.text_body == "Plain words"
      assert stored(message).metadata["html_body"] == @brand
      assert stored(message).body == "Plain words"

      emails_module_enabled!()
      email_log_fixture(%{"inbox_message_uuid" => message.uuid}, "failed")
      outbound_result({:ok, %{id: "ok"}})

      assert {:ok, :pending} =
               Messages.retry_external(ctx.alice_scope, ctx.alice_mb, message.uuid)

      await_external(message.uuid)
      assert_received {:outbound, retried, _, _}
      assert retried.html_body == @brand
    end

    test "without html_body the email is built as before", ctx do
      assert {:ok, message} =
               send_external(ctx, %{"body_format" => "markdown", "body" => "**hi**"})

      assert_received {:outbound, email, _, _}
      assert email.html_body =~ "<strong>hi</strong>"
      refute Map.has_key?(stored(message).metadata, "html_body")
    end

    test "html_body absent from viewer projection", ctx do
      assert {:ok, returned} =
               send_external(ctx, %{"to" => "@#{ctx.bob.username}, client@example.com"},
                 html_body: @brand
               )

      refute Map.has_key?(returned.metadata, "html_body")
      raw = stored(returned)
      assert raw.metadata["html_body"] == @brand

      for viewer <- [ctx.alice_mb.uuid, ctx.bob_mb.uuid, nil] do
        refute Map.has_key?(Messages.project_for_viewer(raw, viewer).metadata, "html_body")
      end

      assert {:ok, %{message: fetched}} = Messages.fetch_for_mailbox(ctx.alice_mb.uuid, raw.uuid)
      refute Map.has_key?(fetched.metadata, "html_body")

      assert {:ok, %{message: received}} = Messages.fetch_for_mailbox(ctx.bob_mb.uuid, raw.uuid)
      refute Map.has_key?(received.metadata, "html_body")

      assert {:ok, %{message: scoped}} = Messages.fetch_for_scope(ctx.alice_scope, raw.uuid)
      refute Map.has_key?(scoped.metadata, "html_body")

      for folder <- [{ctx.alice_mb, "sent"}, {ctx.bob_mb, "inbox"}] do
        {mailbox, name} = folder
        assert [%{message: listed}] = Messages.list_folder(mailbox.uuid, name)
        refute Map.has_key?(listed.metadata, "html_body")
      end

      assert [thread_message] = Messages.list_thread(raw.thread_uuid)
      refute Map.has_key?(thread_message.metadata, "html_body")
    end

    test "an internal-only message does not keep the html", ctx do
      assert {:ok, message} =
               send_external(ctx, %{"to" => "@#{ctx.bob.username}"}, html_body: @brand)

      refute Map.has_key?(stored(message).metadata, "html_body")
      assert message.external_status == :none
    end

    test "a mixed message keeps it, and its retry uses it", ctx do
      outbound_result({:error, :smtp_down})

      assert {:ok, message} =
               send_external(ctx, %{"to" => "@#{ctx.bob.username}, client@example.com"},
                 html_body: @brand
               )

      assert stored(message).metadata["html_body"] == @brand
      assert_received {:outbound, %{html_body: @brand}, _, _}

      emails_module_enabled!()
      email_log_fixture(%{"inbox_message_uuid" => message.uuid}, "failed")
      outbound_result({:ok, %{id: "ok"}})

      assert {:ok, :pending} =
               Messages.retry_external(ctx.alice_scope, ctx.alice_mb, message.uuid)

      await_external(message.uuid)
      assert_received {:outbound, %{html_body: @brand}, _, _}
    end

    test "a repeat of the send does not hand the html back either", ctx do
      {:ok, first} = send_external(ctx, %{}, html_body: @brand, idempotency_key: "k-1")

      {:ok, again} =
        Messages.send_message(
          ctx.alice_scope,
          ctx.alice_mb,
          external_attrs(ctx),
          html_body: @brand,
          idempotency_key: "k-1"
        )

      assert again.uuid == first.uuid
      refute Map.has_key?(again.metadata, "html_body")
    end

    test "oversize html_body refused", ctx do
      limit = 256 * 1024
      too_big = String.duplicate("a", limit + 1)

      assert {:error, :html_body_too_large} = send_external(ctx, %{}, html_body: too_big)
      assert message_count() == 0

      assert {:ok, message} = send_external(ctx, %{}, html_body: String.duplicate("a", limit))
      assert byte_size(stored(message).metadata["html_body"]) == limit
    end

    test "an html_body the database cannot store is refused", ctx do
      for bad <- [<<0xFF, 0xFE>>, "a\0b", :html, 5] do
        assert {:error, :invalid_html_body} = send_external(ctx, %{}, html_body: bad)
      end

      assert message_count() == 0
    end
  end

  describe "personalize_from_name" do
    test "personalized From on bound shared identity", ctx do
      assert {:ok, _} = send_from_desk(ctx, ctx.alice_scope)
      assert_received {:outbound, plain, _, _}
      assert {"Desk", "noreply@company.test"} = plain.from

      {:ok, _} =
        Identities.update_identity(ctx.manager, ctx.bound, %{"personalize_from_name" => true})

      assert {:ok, message} = send_from_desk(ctx, ctx.alice_scope)
      assert_received {:outbound, email, _, _}
      assert email.from == {"Alice Smith | Desk", "noreply@company.test"}
      assert stored(message).metadata["identity"]["from_name"] == "Alice Smith | Desk"
    end

    test "a bound identity's own name is kept after the user's", ctx do
      {:ok, _} =
        Identities.update_identity(ctx.manager, ctx.bound, %{
          "from_name" => "Orders",
          "personalize_from_name" => true
        })

      assert {:ok, _} = send_from_desk(ctx, ctx.alice_scope)
      assert_received {:outbound, email, _, _}
      assert {"Alice Smith | Orders", _} = email.from
    end

    # Documents what a retry fixes (the user's name) and what it reads anew at
    # delivery (the identity: its name, its flag), see `External.retry/3`.
    test "a retry takes the identity as it is now, with the first sender's name", ctx do
      {:ok, bound} =
        Identities.update_identity(ctx.manager, ctx.bound, %{"personalize_from_name" => true})

      outbound_result({:error, :smtp_down})
      assert {:ok, message} = send_from_desk(ctx, ctx.alice_scope)
      assert_received {:outbound, %{from: {"Alice Smith | Desk", _}}, _, _}

      {:ok, _} =
        Identities.update_identity(ctx.manager, bound, %{"from_name" => "Orders"})

      emails_module_enabled!()
      email_log_fixture(%{"inbox_message_uuid" => message.uuid}, "failed")
      outbound_result({:ok, %{id: "ok"}})

      assert {:ok, :pending} = Messages.retry_external(ctx.carol_scope, ctx.desk, message.uuid)
      await_external(message.uuid)

      assert_received {:outbound, %{from: {"Alice Smith | Orders", _}}, _, _}
    end

    test "retry by another user keeps the original From", ctx do
      {:ok, _} =
        Identities.update_identity(ctx.manager, ctx.bound, %{"personalize_from_name" => true})

      outbound_result({:error, :smtp_down})
      assert {:ok, message} = send_from_desk(ctx, ctx.alice_scope)
      assert_received {:outbound, original, _, _}
      assert {"Alice Smith | Desk", _} = original.from

      emails_module_enabled!()
      email_log_fixture(%{"inbox_message_uuid" => message.uuid}, "failed")
      outbound_result({:ok, %{id: "ok"}})

      assert {:ok, :pending} = Messages.retry_external(ctx.carol_scope, ctx.desk, message.uuid)
      await_external(message.uuid)

      assert_received {:outbound, retried, _, opts}
      assert retried.from == original.from
      assert opts[:user_uuid] == ctx.carol.uuid
    end
  end
end
