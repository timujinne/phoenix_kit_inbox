defmodule PhoenixKitInbox.Web.ComposeLiveTest do
  use PhoenixKitInbox.LiveCase

  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Schemas.Mailbox
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

    view
    |> form("form", %{
      "to" => ctx.bob.email,
      "cc" => "",
      "bcc" => "",
      "subject" => "Hi Bob",
      "body" => "How's it going?"
    })
    |> render_submit()

    assert {to, _flash} = assert_redirect(view)

    assert to =~ "folder=sent"

    assert [%{message: message}] = Messages.list_folder(ctx.bob_mb.uuid, "inbox")
    assert message.subject == "Hi Bob"
    assert message.body_format == "markdown"
  end

  test "an unknown recipient re-renders the form with an error", ctx do
    {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")

    view
    |> form("form", %{
      "to" => "nobody@example.com",
      "cc" => "",
      "bcc" => "",
      "subject" => "Lost",
      "body" => "..."
    })
    |> render_submit()

    html = render_async(view)
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
    render_async(view)

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
    render_async(view)

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

    view
    |> form("form", %{"to" => ctx.bob.email, "subject" => "Re: Question", "body" => "A"})
    |> render_submit()

    assert_redirect(view)

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
    render_async(view)
    assert [%{message: draft}] = Messages.list_folder(ctx.alice_mb.uuid, "drafts")

    :ok = Messages.purge(scope_for_user(ctx.alice), ctx.alice_mb, original.uuid)

    {:ok, resumed, _html} = live(ctx.conn, "/en/admin/inbox/compose?draft=#{draft.uuid}")

    resumed
    |> form("form", %{"to" => ctx.bob.email, "subject" => "Re: Q", "body" => "now"})
    |> render_submit()

    assert_redirect(resumed)

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
    render_async(view)
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

  test "a URL patch cannot read a draft after mailbox access is revoked", ctx do
    shared = shared_mailbox_fixture(ctx.bob, %{name: "Private desk"})
    grant_fixture(shared, ctx.alice, "write")
    {:ok, view, _} = live(ctx.conn, "/en/admin/inbox/compose")

    Repo.delete_all(MailboxGrant)

    {:ok, draft} =
      Messages.save_draft(scope_for(ctx.bob), shared, %{
        "subject" => "After revocation",
        "body" => "Private new draft"
      })

    html =
      render_patch(view, "/en/admin/inbox/compose?mailbox=#{shared.uuid}&draft=#{draft.uuid}")

    refute html =~ "Private new draft"
    refute has_element?(view, "select[name='mailbox'] option[value='#{shared.uuid}']")
  end

  test "switching mailbox after saving starts a new draft and preserves the original", ctx do
    desk = shared_mailbox_fixture(ctx.alice, %{name: "Desk"})
    {:ok, view, _} = live(ctx.conn, "/en/admin/inbox/compose")

    view
    |> form("#compose-form", %{subject: "Original draft", body: "Still writing"})
    |> render_change()

    view |> element("button[phx-click='save_draft']") |> render_click()
    render_async(view)
    assert [%{message: original}] = Messages.list_folder(ctx.alice_mb.uuid, "drafts")

    view |> element("select[name='mailbox']") |> render_change(%{"mailbox" => desk.uuid})
    view |> element("button[phx-click='save_draft']") |> render_click()
    render_async(view)

    assert [%{message: another}] = Messages.list_folder(desk.uuid, "drafts")
    assert another.uuid != original.uuid
    assert another.body == "Still writing"
    assert [%{message: %{uuid: uuid}}] = Messages.list_folder(ctx.alice_mb.uuid, "drafts")
    assert uuid == original.uuid
  end

  test "switching mailboxes cannot load signatures after access is revoked", ctx do
    shared = shared_mailbox_fixture(ctx.bob, %{name: "Private desk"})
    grant_fixture(shared, ctx.alice, "write")
    {:ok, view, _} = live(ctx.conn, "/en/admin/inbox/compose")
    Repo.delete_all(MailboxGrant)

    {:ok, _} =
      PhoenixKitInbox.Signatures.create_signature(
        scope_for(ctx.bob, ["inbox", "inbox.manage_shared"]),
        shared,
        %{label: "Secret", body: "New private signature", is_default: true}
      )

    html = render_hook(view, "select_mailbox", %{"mailbox" => shared.uuid})
    refute html =~ "New private signature"
  end

  defp scope_for_user(user), do: PhoenixKitInbox.DataCase.scope_for(user)

  test "a user without the inbox permission can't compose", %{conn: conn} do
    conn = put_test_scope(conn, fake_scope(permissions: [], roles: []))

    {:ok, _view, html} = live(conn, "/en/admin/inbox/compose")

    assert html =~ "You don&#39;t have permission to use Inbox."
  end

  defp personal_mailbox(user), do: Repo.get_by(Mailbox, owner_uuid: user.uuid, kind: "user")

  test "opening Compose first creates the personal mailbox and defaults to it", ctx do
    carol = user_fixture()
    shared = shared_mailbox_fixture(ctx.bob, %{name: "Front desk"})
    grant_fixture(shared, carol, "write")
    refute personal_mailbox(carol)

    conn = put_test_scope(ctx.conn, fake_scope(user_uuid: carol.uuid, email: carol.email))
    {:ok, view, _html} = live(conn, "/en/admin/inbox/compose")

    personal = personal_mailbox(carol)
    assert personal
    assert has_element?(view, "select[name='mailbox'] option[selected][value='#{personal.uuid}']")
    assert has_element?(view, "select[name='mailbox'] option[value='#{shared.uuid}']")
  end

  test "Compose without the inbox permission creates no mailbox" do
    dave = user_fixture()

    conn =
      put_test_scope(
        Phoenix.ConnTest.build_conn(),
        fake_scope(user_uuid: dave.uuid, permissions: [], roles: [])
      )

    {:ok, _view, _html} = live(conn, "/en/admin/inbox/compose")

    refute personal_mailbox(dave)
  end

  test "the From, Send as, Reply-To and Signature labels are not cut off", ctx do
    shared = shared_mailbox_fixture(ctx.bob, %{name: "Front desk"})
    grant_fixture(shared, ctx.alice, "write")

    {:ok, _view, html} = live(ctx.conn, "/en/admin/inbox/compose")

    refute html =~ "text-sm w-16 shrink-0"
    assert html =~ "whitespace-nowrap"
  end
end
