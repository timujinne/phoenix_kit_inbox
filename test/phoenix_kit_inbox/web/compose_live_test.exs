defmodule PhoenixKitInbox.Web.ComposeLiveTest do
  use PhoenixKitInbox.LiveCase

  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Schemas.MailboxGrant
  alias PhoenixKitInbox.Test.Repo

  setup %{conn: conn} do
    enable_inbox!()
    alice = user_fixture()
    bob = user_fixture()

    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)

    conn = put_test_scope(conn, fake_scope(user_uuid: alice.uuid, email: alice.email))

    %{conn: conn, alice: alice, bob: bob, alice_mb: alice_mb, bob_mb: bob_mb}
  end

  test "renders the compose form", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/en/admin/inbox/compose")

    assert html =~ "To"
    assert html =~ "Subject"
    assert html =~ "Send"
  end

  test "sending delivers the message and redirects to Sent", ctx do
    {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")

    assert {:error, {:live_redirect, %{to: to}}} =
             view
             |> form("form", %{
               "to" => ctx.bob.email,
               "cc" => "",
               "bcc" => "",
               "subject" => "Hi Bob",
               "body" => "How's it going?"
             })
             |> render_submit()

    assert to =~ "folder=sent"

    assert [%{message: message}] = Messages.list_folder(ctx.bob_mb.uuid, "inbox")
    assert message.subject == "Hi Bob"
    assert message.body_format == "markdown"
  end

  test "an unknown recipient re-renders the form with an error", ctx do
    {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")

    html =
      view
      |> form("form", %{
        "to" => "nobody@example.com",
        "cc" => "",
        "bcc" => "",
        "subject" => "Lost",
        "body" => "..."
      })
      |> render_submit()

    assert html =~ "No recipient matches"
    assert Messages.list_folder(ctx.alice_mb.uuid, "sent") == []
  end

  test "saving a draft keeps it in the drafts folder", ctx do
    {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")

    view
    |> form("form", %{
      "to" => "",
      "cc" => "",
      "bcc" => "",
      "subject" => "Later",
      "body" => "Unfinished"
    })
    |> render_change()

    view |> element("button[phx-click='save_draft']") |> render_click()

    assert [%{message: draft}] = Messages.list_folder(ctx.alice_mb.uuid, "drafts")
    assert draft.subject == "Later"
    assert draft.status == "draft"
  end

  test "a saved draft reopens with its recipients", ctx do
    {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")

    view
    |> form("form", %{
      "to" => "@#{ctx.bob.username}",
      "cc" => "someone-half",
      "bcc" => ctx.bob.email,
      "subject" => "Come back to this",
      "body" => ""
    })
    |> render_change()

    view |> element("button[phx-click='save_draft']") |> render_click()

    assert [%{message: draft}] = Messages.list_folder(ctx.alice_mb.uuid, "drafts")

    {:ok, reopened, _html} = live(ctx.conn, "/en/admin/inbox/compose?draft=#{draft.uuid}")

    assert has_element?(reopened, "input[name='to'][value='@#{ctx.bob.username}']")
    assert has_element?(reopened, "input[name='cc'][value='someone-half']")
    assert has_element?(reopened, "input[name='bcc'][value='#{ctx.bob.email}']")
    assert has_element?(reopened, "input[name='subject'][value='Come back to this']")
  end

  test "replying prefills the recipient and a Re: subject", ctx do
    {:ok, message} =
      Messages.send_message(ctx.bob_mb, ctx.bob.uuid, %{
        "to" => ctx.alice.email,
        "subject" => "Original",
        "body" => "Quote this"
      })

    {:ok, _view, html} = live(ctx.conn, "/en/admin/inbox/compose?reply_to=#{message.uuid}")

    assert html =~ "Re: Original"
    # The sender's handle, which resolves back to them through the @ rule.
    assert html =~ "@#{ctx.bob.username}"
    assert html =~ "&gt; Quote this"
  end

  test "forwarding prefills a Fwd: subject and no recipient", ctx do
    {:ok, message} =
      Messages.send_message(ctx.bob_mb, ctx.bob.uuid, %{
        "to" => ctx.alice.email,
        "subject" => "Original",
        "body" => "Pass it on"
      })

    {:ok, _view, html} = live(ctx.conn, "/en/admin/inbox/compose?forward=#{message.uuid}")

    assert html =~ "Fwd: Original"
    assert html =~ "&gt; Pass it on"
  end

  test "a reply can be sent from another mailbox the user writes to", ctx do
    shared = shared_mailbox_fixture(ctx.alice, %{name: "Alice's desk"})

    {:ok, original} =
      Messages.send_message(ctx.bob_mb, ctx.bob.uuid, %{
        "to" => ctx.alice.email,
        "subject" => "Question"
      })

    {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose?reply_to=#{original.uuid}")

    render_hook(view, "select_mailbox", %{"mailbox" => shared.uuid})

    assert {:error, {:live_redirect, _}} =
             view
             |> form("form", %{"to" => ctx.bob.email, "subject" => "Re: Question", "body" => "A"})
             |> render_submit()

    assert [%{message: reply}] = Messages.list_folder(shared.uuid, "sent")
    assert reply.parent_uuid == original.uuid
    assert reply.thread_uuid == original.thread_uuid
  end

  test "a resumed draft whose parent copy was purged still sends", ctx do
    {:ok, original} =
      Messages.send_message(ctx.bob_mb, ctx.bob.uuid, %{"to" => ctx.alice.email, "subject" => "Q"})

    {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose?reply_to=#{original.uuid}")

    view
    |> form("form", %{"to" => ctx.bob.email, "subject" => "Re: Q", "body" => "later"})
    |> render_change()

    view |> element("button[phx-click='save_draft']") |> render_click()
    assert [%{message: draft}] = Messages.list_folder(ctx.alice_mb.uuid, "drafts")

    :ok = Messages.purge(scope_for_user(ctx.alice), ctx.alice_mb, original.uuid)

    {:ok, resumed, _html} = live(ctx.conn, "/en/admin/inbox/compose?draft=#{draft.uuid}")

    assert {:error, {:live_redirect, _}} =
             resumed
             |> form("form", %{"to" => ctx.bob.email, "subject" => "Re: Q", "body" => "now"})
             |> render_submit()

    assert [%{message: sent}] = Messages.list_folder(ctx.alice_mb.uuid, "sent")
    assert sent.uuid == draft.uuid
  end

  test "discarding a draft the user can no longer write to says so and stays", ctx do
    shared = shared_mailbox_fixture(ctx.bob, %{name: "Bob's desk"})
    grant_fixture(shared, ctx.alice, "write")

    {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose?mailbox=#{shared.uuid}")

    view
    |> form("form", %{"to" => "", "subject" => "Doomed", "body" => ""})
    |> render_change()

    view |> element("button[phx-click='save_draft']") |> render_click()
    assert [_] = Messages.list_folder(shared.uuid, "drafts")

    Repo.delete_all(MailboxGrant)

    html = view |> element("button[phx-click='discard']") |> render_click()

    assert html =~ "access to this mailbox"
    refute html =~ "Draft discarded."
    assert [_] = Messages.list_folder(shared.uuid, "drafts")
  end

  test "an archived mailbox is not offered as a sender", ctx do
    active = shared_mailbox_fixture(ctx.bob, %{name: "Open desk"})
    archived = shared_mailbox_fixture(ctx.bob, %{name: "Closed desk", status: "archived"})
    grant_fixture(active, ctx.alice, "write")
    grant_fixture(archived, ctx.alice, "write")

    {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose?mailbox=#{archived.uuid}")

    assert has_element?(view, "select[name='mailbox'] option[value='#{active.uuid}']")
    refute has_element?(view, "select[name='mailbox'] option[value='#{archived.uuid}']")
    refute has_element?(view, "select[name='mailbox'] option[selected][value='#{archived.uuid}']")
  end

  defp scope_for_user(user), do: PhoenixKitInbox.DataCase.scope_for(user)

  test "a user without the inbox permission can't compose", %{conn: conn} do
    conn = put_test_scope(conn, fake_scope(permissions: [], roles: []))

    {:ok, _view, html} = live(conn, "/en/admin/inbox/compose")

    assert html =~ "You don&#39;t have permission to use Inbox."
  end
end
