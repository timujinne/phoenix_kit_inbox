defmodule PhoenixKitInbox.Web.InboxLiveTest do
  use PhoenixKitInbox.LiveCase

  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages

  setup %{conn: conn} do
    enable_inbox!()
    alice = user_fixture()
    bob = user_fixture()

    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)

    conn = put_test_scope(conn, fake_scope(user_uuid: alice.uuid, email: alice.email))

    %{conn: conn, alice: alice, bob: bob, alice_mb: alice_mb, bob_mb: bob_mb}
  end

  test "renders the folder sidebar and the empty reading pane", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/en/admin/inbox")

    assert html =~ "Inbox"
    assert html =~ "Sent"
    assert html =~ "Drafts"
    assert html =~ "Spam"
    assert html =~ "Trash"
    assert html =~ "Archive"
    assert html =~ "Select any message in the list to view it here."
  end

  test "an empty folder shows the empty state", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/en/admin/inbox")

    assert html =~ "Empty list."
  end

  test "a received message appears in the list", %{conn: conn, alice: alice, bob: bob} do
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)

    {:ok, _} =
      Messages.send_message(bob_mb, bob.uuid, %{
        "to" => alice.email,
        "subject" => "Ping from Bob",
        "body" => "Are you there?"
      })

    {:ok, _view, html} = live(conn, "/en/admin/inbox")

    assert html =~ "Ping from Bob"
    assert html =~ "Are you there?"
  end

  test "opening a message renders it and marks it seen", %{conn: conn, alice: alice, bob: bob} do
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)
    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)

    {:ok, message} =
      Messages.send_message(bob_mb, bob.uuid, %{
        "to" => alice.email,
        "subject" => "Open me",
        "body" => "The body text"
      })

    {:ok, view, _html} = live(conn, "/en/admin/inbox")

    html = view |> element("li[phx-value-uuid='#{message.uuid}']") |> render_click()

    assert html =~ "The body text"
    assert html =~ "Reply"

    assert {:ok, %{delivery: delivery}} = Messages.fetch_for_mailbox(alice_mb.uuid, message.uuid)
    assert delivery.seen_at
  end

  describe "a Markdown body" do
    setup %{alice: alice, bob: bob, bob_mb: bob_mb} do
      {:ok, message} =
        Messages.send_message(bob_mb, bob.uuid, %{
          "to" => alice.email,
          "subject" => "Formatted",
          "body_format" => "markdown",
          "body" =>
            "**Bold** {{name}}\n\n![pixel](http://tracker.example/p.png) " <>
              "[bad](javascript:alert(1)) <img src=x onerror=alert(1)>"
        })

      %{message: message}
    end

    test "is shown formatted, with images as links and nothing executable", ctx do
      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox?message=#{ctx.message.uuid}")

      assert has_element?(view, "#message-body strong", "Bold")
      assert has_element?(view, "#message-body a[href='http://tracker.example/p.png']", "pixel")
      refute has_element?(view, "#message-body img")
      refute has_element?(view, "#message-body [onerror]")
      refute has_element?(view, "#message-body a[href^='javascript']")
      assert view |> element("#message-body") |> render() =~ "{{name}}"
    end

    test "is previewed in the list as text", ctx do
      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox")

      assert view |> element("li[phx-value-uuid='#{ctx.message.uuid}']") |> render() =~
               "Bold {{name}}"
    end
  end

  test "a text body is shown as typed, markup and all", ctx do
    {:ok, message} =
      Messages.send_message(ctx.bob_mb, ctx.bob.uuid, %{
        "to" => ctx.alice.email,
        "subject" => "Plain",
        "body" => "<b>not bold</b> **not bold either**"
      })

    {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox?message=#{message.uuid}")

    refute has_element?(view, "#message-body b")
    refute has_element?(view, "#message-body strong")
    assert view |> element("#message-body") |> render() =~ "&lt;b&gt;not bold&lt;/b&gt;"
  end

  test "switching folders patches the URL", %{conn: conn, alice_mb: alice_mb} do
    {:ok, view, _html} = live(conn, "/en/admin/inbox")

    view |> element("button[phx-value-folder='sent']") |> render_click()

    assert_patched(view, PhoenixKitInbox.Paths.inbox(mailbox: alice_mb.uuid, folder: "sent"))
  end

  test "a message can be trashed from the reading pane", %{conn: conn, alice: alice, bob: bob} do
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)
    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)

    {:ok, message} =
      Messages.send_message(bob_mb, bob.uuid, %{"to" => alice.email, "subject" => "Junk"})

    {:ok, view, _html} = live(conn, "/en/admin/inbox?message=#{message.uuid}")

    view
    |> element("button[phx-click='move'][phx-value-folder='trash']")
    |> render_click()

    assert Messages.list_folder(alice_mb.uuid, "inbox") == []
    assert length(Messages.list_folder(alice_mb.uuid, "trash")) == 1
  end

  test "search filters the list", %{conn: conn, alice: alice, bob: bob} do
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)

    for subject <- ["Invoice March", "Holiday plans"] do
      {:ok, _} =
        Messages.send_message(bob_mb, bob.uuid, %{"to" => alice.email, "subject" => subject})
    end

    {:ok, view, _html} = live(conn, "/en/admin/inbox?search=Invoice")

    html = render(view)
    assert html =~ "Invoice March"
    refute html =~ "Holiday plans"
  end

  test "a bcc recipient is hidden from the other readers", ctx do
    carol = user_fixture()
    {:ok, carol_mb} = Mailboxes.ensure_user_mailbox(carol)

    {:ok, message} =
      Messages.send_message(ctx.bob_mb, ctx.bob.uuid, %{
        "to" => ctx.alice.email,
        "bcc" => carol.email,
        "subject" => "Blind copy"
      })

    {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox?message=#{message.uuid}")

    assert has_element?(view, "#recipient-#{ctx.alice_mb.uuid}")
    refute has_element?(view, "#recipient-#{carol_mb.uuid}")
  end

  test "the sender sees the bcc recipients of their own message", ctx do
    carol = user_fixture()
    {:ok, carol_mb} = Mailboxes.ensure_user_mailbox(carol)

    {:ok, message} =
      Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
        "to" => ctx.bob.email,
        "bcc" => carol.email,
        "subject" => "Blind copy"
      })

    {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox?folder=sent&message=#{message.uuid}")

    assert has_element?(view, "#recipient-#{carol_mb.uuid}")
  end

  test "a read grantee's forged move and purge are refused", ctx do
    shared = shared_mailbox_fixture(ctx.bob, %{name: "Read only here"})
    grant_fixture(shared, ctx.alice, "read")

    {:ok, message} =
      Messages.send_message(ctx.bob_mb, ctx.bob.uuid, %{
        "to" => shared.slug,
        "subject" => "Stays put"
      })

    {:ok, view, _html} =
      live(ctx.conn, "/en/admin/inbox?mailbox=#{shared.uuid}&message=#{message.uuid}")

    render_hook(view, "move", %{"uuid" => message.uuid, "folder" => "trash"})
    render_hook(view, "delete_forever", %{"uuid" => message.uuid})

    assert [%{message: %{uuid: uuid}}] = Messages.list_folder(shared.uuid, "inbox")
    assert uuid == message.uuid
  end

  test "a user without the inbox permission sees only the denial notice", %{conn: conn} do
    conn = put_test_scope(conn, fake_scope(permissions: [], roles: []))

    {:ok, _view, html} = live(conn, "/en/admin/inbox")

    assert html =~ "You don&#39;t have permission to use Inbox."
    refute html =~ "Empty list."
  end
end
