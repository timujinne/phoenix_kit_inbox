defmodule PhoenixKitInbox.Web.MySettingsLiveTest do
  use PhoenixKitInbox.LiveCase

  alias PhoenixKit.Integrations
  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Schemas.Identity
  alias PhoenixKitInbox.Schemas.Signature
  alias PhoenixKitInbox.Signatures
  alias PhoenixKitInbox.Test.Repo

  @path "/en/dashboard/inbox-settings"

  setup %{conn: conn} do
    enable_inbox!()
    alice = user_fixture()
    bob = user_fixture()
    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)

    %{conn: conn, alice: alice, bob: bob, alice_mb: alice_mb, bob_mb: bob_mb}
  end

  defp as(conn, user, permissions \\ ["inbox"]),
    do: put_test_scope(conn, scope_for(user, permissions))

  test "a user without Inbox sees no settings", ctx do
    {:ok, view, _html} = live(as(ctx.conn, ctx.alice, []), @path)

    refute has_element?(view, "#my-signatures")
    refute has_element?(view, "#my-identities")
  end

  test "a forged event from a user without Inbox changes nothing", ctx do
    {:ok, view, _html} = live(as(ctx.conn, ctx.alice, []), @path)

    render_click(view, "sig_new", %{})
    render_submit(view, "sig_save", %{"signature" => %{"label" => "Forged", "body" => "x"}})

    assert Signatures.list(ctx.alice_mb.uuid) == []
  end

  test "the page links to the inbox", ctx do
    {:ok, view, _html} = live(as(ctx.conn, ctx.alice), @path)

    assert has_element?(view, "#open-inbox[href*='/admin/inbox']")
  end

  describe "signatures" do
    test "a signature is added, made default, and deleted", ctx do
      {:ok, view, _html} = live(as(ctx.conn, ctx.alice), @path)

      view |> element("#my-signatures button[phx-click='sig_new']") |> render_click()

      view
      |> form("#my-signatures-form", %{
        "signature" => %{"label" => "Work", "body" => "**Alice**", "is_default" => "true"}
      })
      |> render_submit()

      assert [%Signature{label: "Work", is_default: true} = sig] =
               Signatures.list(ctx.alice_mb.uuid)

      assert has_element?(view, "#signature-#{sig.uuid} strong", "Alice")

      view |> element("#signature-#{sig.uuid} button[phx-click='sig_delete']") |> render_click()

      assert Signatures.list(ctx.alice_mb.uuid) == []
    end

    test "editing someone else's signature by a forged uuid is refused", ctx do
      {:ok, bobs} =
        Signatures.create_signature(scope_for(ctx.bob), ctx.bob_mb, %{
          "label" => "Bob",
          "body" => "Bob"
        })

      {:ok, view, _html} = live(as(ctx.conn, ctx.alice), @path)

      # The edit button only exists for the user's own; a forged edit is ignored…
      render_click(view, "sig_edit", %{"uuid" => bobs.uuid})
      refute has_element?(view, "#my-signatures-form")

      # …and a forged delete is refused by the context.
      render_click(view, "sig_delete", %{"uuid" => bobs.uuid})

      assert has_element?(view, "#flash-error")
      assert Repo.get(Signature, bobs.uuid).body == "Bob"
    end
  end

  describe "Reply-To" do
    test "the default is saved among the user's own addresses", ctx do
      desk = shared_mailbox_fixture(ctx.bob, %{name: "Desk", address: "desk@company.test"})
      grant_fixture(desk, ctx.alice, "write")

      {:ok, view, _html} = live(as(ctx.conn, ctx.alice), @path)

      view |> form("#reply-to-form", %{"reply_to" => "desk@company.test"}) |> render_submit()

      assert Repo.reload(ctx.alice_mb).settings["reply_to"] == "desk@company.test"
    end

    test "a forged address is refused", ctx do
      {:ok, view, _html} = live(as(ctx.conn, ctx.alice), @path)

      render_submit(view, "save_reply_to", %{"reply_to" => "ceo@company.test"})

      assert has_element?(view, "#flash-error")
      refute Repo.reload(ctx.alice_mb).settings["reply_to"]
    end
  end

  describe "senders" do
    test "a personal sender is added on the user's own mail connection", ctx do
      own = mail_integration_fixture({:user, ctx.alice.uuid}, username: "alice@own.test")
      {:ok, view, _html} = live(as(ctx.conn, ctx.alice), @path)

      assert has_element?(view, "#my-identities button[phx-click='ident_new']")
      view |> element("#my-identities button[phx-click='ident_new']") |> render_click()

      view
      |> form("#my-identities-form", %{
        "identity" => %{"label" => "Mine", "from_name" => "", "integration_uuid" => own}
      })
      |> render_submit()

      assert [%{identity: %Identity{label: "Mine"} = identity}] =
               Identities.list_personal(scope_for(ctx.alice))

      assert has_element?(view, "#identity-#{identity.uuid}", "alice@own.test")
    end

    test "another user's connection, forged into the form, is refused", ctx do
      bobs = mail_integration_fixture({:user, ctx.bob.uuid})
      {:ok, view, _html} = live(as(ctx.conn, ctx.alice), @path)

      render_submit(view, "ident_save", %{
        "identity" => %{"label" => "Bob's", "integration_uuid" => bobs}
      })

      assert has_element?(view, "#flash-error")
      assert Repo.aggregate(Identity, :count) == 0
    end

    test "a broken sender is marked", ctx do
      own = mail_integration_fixture({:user, ctx.alice.uuid})

      {:ok, identity} =
        Identities.create_personal(scope_for(ctx.alice), %{
          "label" => "Mine",
          "integration_uuid" => own
        })

      :ok = Integrations.remove_connection(own, nil, owner: {:user, ctx.alice.uuid})

      {:ok, view, _html} = live(as(ctx.conn, ctx.alice), @path)

      assert has_element?(view, "#identity-#{identity.uuid} .badge-error", "Broken")
    end

    test "the link to the user's mail connections needs the integrations permission", ctx do
      {:ok, view, _html} = live(as(ctx.conn, ctx.alice), @path)
      refute has_element?(view, "#my-integrations-link")

      {:ok, view, _html} = live(as(ctx.conn, ctx.alice, ["inbox", "integrations"]), @path)
      assert has_element?(view, "#my-integrations-link[href*='/profile/settings/integrations']")
    end
  end
end
