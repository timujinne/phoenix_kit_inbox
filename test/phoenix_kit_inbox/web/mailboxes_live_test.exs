defmodule PhoenixKitInbox.Web.MailboxesLiveTest do
  use PhoenixKitInbox.LiveCase

  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Signatures

  setup %{conn: conn} do
    enable_inbox!()
    alice = user_fixture()

    %{conn: conn, alice: alice}
  end

  defp as(conn, user, permissions) do
    put_test_scope(
      conn,
      fake_scope(user_uuid: user.uuid, email: user.email, roles: [], permissions: permissions)
    )
  end

  test "without inbox.manage_shared the create form is not offered", ctx do
    {:ok, view, _html} = live(as(ctx.conn, ctx.alice, ["inbox"]), "/en/admin/inbox/mailboxes")

    refute has_element?(view, "#new-shared-mailbox-form")
    refute render(view) =~ "Create one above"
  end

  test "a forged create event without inbox.manage_shared creates nothing", ctx do
    {:ok, view, _html} = live(as(ctx.conn, ctx.alice, ["inbox"]), "/en/admin/inbox/mailboxes")

    html =
      render_hook(view, "create", %{
        "mailbox" => %{"name" => "Forged", "slug" => "", "address" => "forged@example.com"}
      })

    assert html =~ "You don&#39;t have permission"
    assert Mailboxes.list_shared_mailboxes() == []
  end

  test "with inbox.manage_shared a shared mailbox is created", ctx do
    conn = as(ctx.conn, ctx.alice, ["inbox", "inbox.manage_shared"])
    {:ok, view, _html} = live(conn, "/en/admin/inbox/mailboxes")

    assert has_element?(view, "#new-shared-mailbox-form")

    view
    |> form("#new-shared-mailbox-form", %{
      "mailbox" => %{"name" => "Front Desk", "slug" => "", "address" => "front@example.com"}
    })
    |> render_submit()

    assert [mailbox] = Mailboxes.list_shared_mailboxes()
    assert mailbox.name == "Front Desk"
    assert mailbox.owner_uuid == ctx.alice.uuid
  end

  describe "the access panel" do
    setup ctx do
      desk = shared_mailbox_fixture(ctx.alice, %{name: "Desk"})

      colleague =
        user_fixture(%{
          first_name: "Cora",
          last_name: "Lee",
          username: "cora",
          email: "cora@x.test"
        })

      other = user_fixture(%{first_name: "Otto", last_name: "Berg", username: "otto"})
      outsider = user_fixture(%{first_name: "Out", last_name: "Sider", inbox_member: false})

      {:ok, view, _html} = live(as(ctx.conn, ctx.alice, ["inbox"]), "/en/admin/inbox/mailboxes")

      view
      |> element("button[phx-click='toggle_grants'][phx-value-uuid='#{desk.uuid}']")
      |> render_click()

      %{desk: desk, colleague: colleague, other: other, outsider: outsider, view: view}
    end

    test "offers colleagues by name to pick from, not a uuid to type", ctx do
      refute has_element?(ctx.view, "#grant-form input[name='user_uuid']")

      assert has_element?(
               ctx.view,
               "#grant-user option[value='#{ctx.colleague.uuid}']",
               "Cora Lee"
             )

      refute has_element?(ctx.view, "#grant-user option[value='#{ctx.outsider.uuid}']")
      refute has_element?(ctx.view, "#grant-user option[value='#{ctx.alice.uuid}']")

      ctx.view |> element("#grant-form") |> render_change(%{"q" => "otto"})

      assert has_element?(ctx.view, "#grant-user option[value='#{ctx.other.uuid}']")
      refute has_element?(ctx.view, "#grant-user option[value='#{ctx.colleague.uuid}']")
    end

    test "a picked colleague gets access and is listed by name", ctx do
      ctx.view
      |> element("#grant-form")
      |> render_submit(%{"user_uuid" => ctx.colleague.uuid, "access" => "write"})

      assert Mailboxes.access_level(ctx.desk, ctx.colleague.uuid) == "write"
      assert has_element?(ctx.view, "#grant-#{ctx.colleague.uuid}", "Cora Lee")
      assert has_element?(ctx.view, "#grant-#{ctx.colleague.uuid}", "@cora")

      ctx.view
      |> element("#grant-#{ctx.colleague.uuid} button[phx-click='revoke']")
      |> render_click()

      assert Mailboxes.access_level(ctx.desk, ctx.colleague.uuid) == nil
    end
  end

  describe "signatures of a shared mailbox" do
    setup ctx do
      desk = shared_mailbox_fixture(ctx.alice, %{name: "Desk"})
      %{desk: desk}
    end

    test "are written from its row by an admin with inbox.manage_shared", ctx do
      conn = as(ctx.conn, ctx.alice, ["inbox", "inbox.manage_shared"])
      {:ok, view, _html} = live(conn, "/en/admin/inbox/mailboxes")

      view
      |> element("button[phx-click='toggle_signatures'][phx-value-uuid='#{ctx.desk.uuid}']")
      |> render_click()

      view |> element("#mailbox-signatures button[phx-click='sig_new']") |> render_click()

      view
      |> form("#mailbox-signatures-form", %{
        "signature" => %{"label" => "Desk", "body" => "The Desk", "is_default" => "true"}
      })
      |> render_submit()

      assert [%{label: "Desk", is_default: true}] = Signatures.list(ctx.desk.uuid)
      assert has_element?(view, "#mailbox-signatures", "The Desk")

      view
      |> element("button[phx-click='toggle_signatures'][phx-value-uuid='#{ctx.desk.uuid}']")
      |> render_click()

      refute has_element?(view, "#mailbox-signatures")
    end

    test "are not offered without inbox.manage_shared, and a forged submit writes nothing",
         ctx do
      {:ok, view, _html} = live(as(ctx.conn, ctx.alice, ["inbox"]), "/en/admin/inbox/mailboxes")

      refute has_element?(view, "button[phx-click='toggle_signatures']")

      render_hook(view, "toggle_signatures", %{"uuid" => ctx.desk.uuid})
      refute has_element?(view, "#mailbox-signatures")

      render_hook(view, "sig_new", %{})
      render_hook(view, "sig_save", %{"signature" => %{"label" => "Forged"}})

      assert Signatures.list(ctx.desk.uuid) == []
    end

    test "a mailbox the viewer only writes to can't be opened, even when forged", ctx do
      other = shared_mailbox_fixture(user_fixture(), %{name: "Elsewhere"})
      grant_fixture(other, ctx.alice, "write")
      conn = as(ctx.conn, ctx.alice, ["inbox", "inbox.manage_shared"])
      {:ok, view, _html} = live(conn, "/en/admin/inbox/mailboxes")

      refute has_element?(
               view,
               "button[phx-click='toggle_signatures'][phx-value-uuid='#{other.uuid}']"
             )

      render_hook(view, "toggle_signatures", %{"uuid" => other.uuid})
      refute has_element?(view, "#mailbox-signatures")
      render_hook(view, "sig_new", %{})
      render_hook(view, "sig_save", %{"signature" => %{"label" => "Forged"}})

      assert Signatures.list(other.uuid) == []
    end

    test "an archived mailbox offers none, and archiving the open one closes it", ctx do
      conn = as(ctx.conn, ctx.alice, ["inbox", "inbox.manage_shared"])
      {:ok, view, _html} = live(conn, "/en/admin/inbox/mailboxes")
      button = "button[phx-click='toggle_signatures'][phx-value-uuid='#{ctx.desk.uuid}']"

      view |> element(button) |> render_click()
      assert has_element?(view, "#mailbox-signatures")

      view
      |> element("button[phx-click='archive'][phx-value-uuid='#{ctx.desk.uuid}']")
      |> render_click()

      refute has_element?(view, "#mailbox-signatures")
      refute has_element?(view, button)

      render_hook(view, "toggle_signatures", %{"uuid" => ctx.desk.uuid})
      refute has_element?(view, "#mailbox-signatures")
    end
  end

  describe "admin events after the grantee lost admin" do
    # The page is open with the grants panel showing when an admin demotes
    # alice: the context refuses what the stale page still offers.
    setup ctx do
      owner = user_fixture()
      shared = shared_mailbox_fixture(owner, %{name: "Owned elsewhere"})
      grant_fixture(shared, ctx.alice, "admin")
      target = user_fixture()

      {:ok, view, _html} = live(as(ctx.conn, ctx.alice, ["inbox"]), "/en/admin/inbox/mailboxes")
      render_hook(view, "toggle_grants", %{"uuid" => shared.uuid})
      grant_fixture(shared, ctx.alice, "write")

      %{shared: shared, target: target, view: view}
    end

    test "grant is refused", ctx do
      html =
        render_hook(ctx.view, "grant", %{"user_uuid" => ctx.target.uuid, "access" => "admin"})

      assert html =~ "access to this mailbox"
      assert Mailboxes.access_level(ctx.shared, ctx.target.uuid) == nil
    end

    test "revoke is refused", ctx do
      grant_fixture(ctx.shared, ctx.target, "read")
      render_hook(ctx.view, "revoke", %{"user_uuid" => ctx.target.uuid})

      assert Mailboxes.access_level(ctx.shared, ctx.target.uuid) == "read"
    end

    test "archive is refused", ctx do
      render_hook(ctx.view, "archive", %{"uuid" => ctx.shared.uuid})

      assert {:ok, %{status: "active"}} = Mailboxes.fetch_mailbox(ctx.shared.uuid)
    end
  end

  describe "who holds access is for the admins" do
    setup ctx do
      owner = user_fixture()
      shared = shared_mailbox_fixture(owner, %{name: "Owned elsewhere"})
      grant_fixture(shared, ctx.alice, "write")
      colleague = user_fixture()
      grant_fixture(shared, colleague, "read")

      {:ok, view, _html} = live(as(ctx.conn, ctx.alice, ["inbox"]), "/en/admin/inbox/mailboxes")

      %{shared: shared, colleague: colleague, owner: owner, view: view}
    end

    test "a forged toggle on a mailbox the user does not administer lists nobody", ctx do
      html = render_hook(ctx.view, "toggle_grants", %{"uuid" => ctx.shared.uuid})

      refute html =~ ctx.colleague.uuid
      refute html =~ ctx.owner.uuid
      refute html =~ "Grant access"
    end

    test "a forged toggle on something that is not a mailbox does nothing", ctx do
      assert render_hook(ctx.view, "toggle_grants", %{"uuid" => "not-a-uuid"}) =~
               "Shared mailboxes"
    end

    test "an admin sees the grants", ctx do
      {:ok, view, _html} =
        live(as(ctx.conn, ctx.owner, ["inbox"]), "/en/admin/inbox/mailboxes")

      html = render_hook(view, "toggle_grants", %{"uuid" => ctx.shared.uuid})

      assert html =~ ctx.colleague.uuid
      assert html =~ "Grant access"
    end
  end
end
