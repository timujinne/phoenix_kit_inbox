defmodule PhoenixKitInbox.Web.ComposeSenderTest do
  @moduledoc "Signatures and Reply-To in the compose form."

  use PhoenixKitInbox.LiveCase

  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Signatures

  setup %{conn: conn} do
    enable_inbox!()
    admin = user_fixture()
    alice = user_fixture()
    bob = user_fixture()
    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)
    desk = shared_mailbox_fixture(admin, %{name: "Desk", address: "desk@company.test"})
    grant_fixture(desk, alice, "write")

    alice_scope = scope_for(alice)
    manage = scope_for(admin, ["inbox", "inbox.manage_shared"])

    {:ok, work} =
      Signatures.create_signature(alice_scope, alice_mb, %{
        "label" => "Work",
        "body" => "Alice\nAcme",
        "is_default" => true
      })

    {:ok, home} =
      Signatures.create_signature(alice_scope, alice_mb, %{"label" => "Home", "body" => "A."})

    {:ok, desk_sig} =
      Signatures.create_signature(manage, desk, %{
        "label" => "Desk",
        "body" => "The Desk team",
        "is_default" => true
      })

    {:ok, bobs} =
      Signatures.create_signature(scope_for(bob), bob_mb, %{
        "label" => "Bob",
        "body" => "Bob's secret line"
      })

    conn = put_test_scope(conn, fake_scope(user_uuid: alice.uuid, email: alice.email))

    %{
      conn: conn,
      alice: alice,
      bob: bob,
      alice_mb: alice_mb,
      bob_mb: bob_mb,
      desk: desk,
      work: work,
      home: home,
      desk_sig: desk_sig,
      bobs: bobs
    }
  end

  defp body(view) do
    view
    |> element("#compose-form textarea[name='body']")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
  end

  describe "signatures" do
    test "a new message starts with the mailbox's default signature", ctx do
      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")

      assert body(view) =~ "-- \nAlice\nAcme"
      assert has_element?(view, "#compose-signature option[selected][value='#{ctx.work.uuid}']")
    end

    test "choosing another one replaces the block left as it was", ctx do
      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")

      view
      |> element("#compose-signature")
      |> render_change(%{"signature" => ctx.home.uuid, "body" => "Hello\n\n-- \nAlice\nAcme"})

      assert body(view) == "Hello\n\n-- \nA."

      view
      |> element("#compose-signature")
      |> render_change(%{"signature" => "", "body" => "Hello\n\n-- \nA."})

      assert body(view) == "Hello"
    end

    test "an edited block is left alone", ctx do
      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")

      view
      |> element("#compose-signature")
      |> render_change(%{
        "signature" => ctx.home.uuid,
        "body" => "Hello\n\n-- \nAlice, CEO\nAcme"
      })

      assert body(view) == "Hello\n\n-- \nAlice, CEO\nAcme"
      assert has_element?(view, "#flash-warning", "edited")
    end

    test "another mailbox's signature can't be pulled in by a forged choice", ctx do
      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")

      view
      |> element("#compose-signature")
      |> render_change(%{"signature" => ctx.bobs.uuid, "body" => "Hi\n\n-- \nAlice\nAcme"})

      refute body(view) =~ "secret"
    end

    test "switching the sending mailbox switches to its default signature", ctx do
      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")

      view
      |> element("#compose-form select[name='mailbox']")
      |> render_change(%{"mailbox" => ctx.desk.uuid, "body" => "Hi\n\n-- \nAlice\nAcme"})

      assert body(view) == "Hi\n\n-- \nThe Desk team"
      assert has_element?(view, "#compose-reply-to option[selected][value='desk@company.test']")
    end

    test "a reopened draft keeps its body as saved", ctx do
      {:ok, draft} =
        Messages.save_draft(scope_for(ctx.alice), ctx.alice_mb, %{
          "subject" => "Draft",
          "body" => "Saved text"
        })

      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose?draft=#{draft.uuid}")

      assert body(view) == "Saved text"
    end
  end

  describe "Reply-To" do
    test "offers the user's email and the shared addresses they write to", ctx do
      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")

      assert has_element?(view, "#compose-reply-to option[value='#{ctx.alice.email}'][selected]")
      assert has_element?(view, "#compose-reply-to option[value='desk@company.test']")
    end

    test "the chosen one is recorded on the message", ctx do
      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")

      {:error, {:live_redirect, _}} =
        view
        |> form("#compose-form", %{
          "to" => "@" <> ctx.bob.username,
          "subject" => "Hi",
          "body" => "x",
          "reply_to" => "desk@company.test"
        })
        |> render_submit()

      assert [%{message: message}] = Messages.list_folder(ctx.bob_mb.uuid, "inbox")
      assert message.metadata["reply_to"] == "desk@company.test"
    end

    test "a forged one is refused and nothing is sent", ctx do
      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")

      render_submit(view, "send", %{
        "to" => "@" <> ctx.bob.username,
        "subject" => "Hi",
        "body" => "x",
        "reply_to" => "ceo@company.test"
      })

      assert has_element?(view, "#flash-error", "Reply-To address")
      assert Messages.list_folder(ctx.bob_mb.uuid, "inbox") == []
    end

    test "from a shared mailbox without an address, no Reply-To is set", ctx do
      notes = shared_mailbox_fixture(ctx.bob, %{name: "Notes"})
      grant_fixture(notes, ctx.alice, "write")

      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose?mailbox=#{notes.uuid}")

      {:error, {:live_redirect, _}} =
        view
        |> form("#compose-form", %{"to" => "@" <> ctx.bob.username, "subject" => "Hi"})
        |> render_submit()

      assert [%{message: message}] = Messages.list_folder(ctx.bob_mb.uuid, "inbox")
      refute Map.has_key?(message.metadata, "reply_to")
    end

    test "a reply goes to the message's Reply-To", ctx do
      {:ok, desk_message} =
        Messages.send_message(scope_for(ctx.bob), ctx.bob_mb, %{
          "to" => "@" <> ctx.alice.username,
          "subject" => "Ask the desk",
          "body" => "x",
          "reply_to" => ctx.bob.email
        })

      {:ok, view, _html} =
        live(
          ctx.conn,
          "/en/admin/inbox/compose?mailbox=#{ctx.alice_mb.uuid}&reply_to=#{desk_message.uuid}"
        )

      assert has_element?(view, "#compose-form input[name='to'][value='#{ctx.bob.email}']")
    end
  end
end
