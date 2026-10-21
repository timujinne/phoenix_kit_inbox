defmodule PhoenixKitInbox.Web.ComposeExternalTest do
  @moduledoc """
  External recipients from the compose form: the "Send as" picker, the
  send, and forged events (an identity of another mailbox, an external
  address without the right to write externally).
  """

  use PhoenixKitInbox.LiveCase

  alias PhoenixKitInbox.External
  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages

  @external ["inbox", "inbox.send_external"]

  setup :outbound_setup

  setup %{conn: conn} do
    enable_inbox!()
    admin = user_fixture()
    alice = user_fixture()
    bob = user_fixture()
    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)
    desk = shared_mailbox_fixture(admin, %{name: "Desk", address: "desk@company.test"})
    other = shared_mailbox_fixture(admin, %{name: "Other"})
    grant_fixture(desk, alice, "write")
    manage = scope_for(admin, ["inbox", "inbox.manage_shared"])
    smtp = mail_integration_fixture(:system, username: "noreply@company.test")

    {:ok, common} =
      Identities.create_shared(manage, %{
        "label" => "Common",
        "from_name" => "Company",
        "integration_uuid" => smtp
      })

    {:ok, desk_identity} =
      Identities.create_shared(manage, %{
        "label" => "Desk sender",
        "integration_uuid" => smtp,
        "mailbox_uuid" => desk.uuid
      })

    {:ok, other_identity} =
      Identities.create_shared(manage, %{
        "label" => "Other sender",
        "integration_uuid" => smtp,
        "mailbox_uuid" => other.uuid
      })

    :ok = External.subscribe(alice_mb.uuid)

    %{
      conn: conn,
      alice: alice,
      bob: bob,
      alice_mb: alice_mb,
      desk: desk,
      common: common,
      desk_identity: desk_identity,
      other_identity: other_identity,
      smtp: smtp
    }
  end

  defp as_alice(ctx, permissions \\ @external) do
    put_test_scope(
      ctx.conn,
      fake_scope(user_uuid: ctx.alice.uuid, email: ctx.alice.email, permissions: permissions)
    )
  end

  defp submit(view, params) do
    view
    |> element("#compose-form")
    |> render_submit(
      Map.merge(
        %{"to" => "", "cc" => "", "bcc" => "", "subject" => "Offer", "body" => "Hello"},
        params
      )
    )
  end

  test "Send as offers the identities that fit the mailbox, inside-only first", ctx do
    {:ok, view, _html} = live(as_alice(ctx), "/en/admin/inbox/compose")

    assert has_element?(view, "#compose-identity option[selected][value='']")
    assert has_element?(view, "#compose-identity option[value='#{ctx.common.uuid}']")
    refute has_element?(view, "#compose-identity option[value='#{ctx.desk_identity.uuid}']")
    refute has_element?(view, "#compose-identity option[value='#{ctx.other_identity.uuid}']")

    {:ok, view, _html} = live(as_alice(ctx), "/en/admin/inbox/compose?mailbox=#{ctx.desk.uuid}")

    assert has_element?(view, "#compose-identity option[value='#{ctx.desk_identity.uuid}']")
    refute has_element?(view, "#compose-identity option[value='#{ctx.common.uuid}']")
  end

  test "without anything to send as, there is no picker", ctx do
    {:ok, view, _html} = live(as_alice(ctx, ["inbox"]), "/en/admin/inbox/compose")
    refute has_element?(view, "#compose-identity")
  end

  test "an external address goes out from the chosen identity, after the redirect", ctx do
    {:ok, view, _html} = live(as_alice(ctx), "/en/admin/inbox/compose")

    assert {:error, {:live_redirect, %{to: to}}} =
             submit(view, %{
               "to" => "@#{ctx.bob.username}, client@example.com",
               "identity_uuid" => ctx.common.uuid
             })

    assert to =~ "folder=sent"
    assert [%{message: message}] = Messages.list_folder(ctx.alice_mb.uuid, "sent")
    await_external(message.uuid)

    assert [%{address: "client@example.com", status: "sent"}] = External.list(message.uuid)
    assert_received {:outbound, %{to: [{"", "client@example.com"}]}, smtp, _opts}
    assert smtp == ctx.smtp
  end

  test "an external address needs a chosen identity", ctx do
    {:ok, view, _html} = live(as_alice(ctx), "/en/admin/inbox/compose")

    html = submit(view, %{"to" => "client@example.com", "identity_uuid" => ""})

    assert html =~ "sender"
    assert Messages.list_folder(ctx.alice_mb.uuid, "sent") == []
  end

  describe "forged events" do
    test "an identity bound to a mailbox the user can't write to is refused", ctx do
      {:ok, view, _html} = live(as_alice(ctx), "/en/admin/inbox/compose")

      html =
        submit(view, %{"to" => "client@example.com", "identity_uuid" => ctx.other_identity.uuid})

      assert html =~ "You can&#39;t send as that sender."
      assert Messages.list_folder(ctx.alice_mb.uuid, "sent") == []
      refute_received {:outbound, _, _, _}
    end

    test "another mailbox's identity is refused from this one", ctx do
      {:ok, view, _html} = live(as_alice(ctx), "/en/admin/inbox/compose")

      html =
        submit(view, %{"to" => "client@example.com", "identity_uuid" => ctx.desk_identity.uuid})

      assert html =~ "can&#39;t be used from this mailbox"
      assert Messages.list_folder(ctx.alice_mb.uuid, "sent") == []
      refute_received {:outbound, _, _, _}
    end

    test "an external address without inbox.send_external is an unknown recipient", ctx do
      {:ok, view, _html} = live(as_alice(ctx, ["inbox"]), "/en/admin/inbox/compose")

      html = submit(view, %{"to" => "client@example.com"})
      assert html =~ "No recipient matches: client@example.com"

      html = submit(view, %{"to" => "client@example.com", "identity_uuid" => ctx.common.uuid})
      assert html =~ "You can&#39;t send as that sender."

      assert Messages.list_folder(ctx.alice_mb.uuid, "sent") == []
      refute_received {:outbound, _, _, _}
    end
  end

  test "a saved draft keeps its chosen identity", ctx do
    {:ok, view, _html} = live(as_alice(ctx), "/en/admin/inbox/compose")

    view
    |> form("#compose-form", %{
      "to" => "client@example.com",
      "subject" => "Later",
      "identity_uuid" => ctx.common.uuid
    })
    |> render_change()

    view |> element("button[phx-click='save_draft']") |> render_click()

    assert [%{message: draft}] = Messages.list_folder(ctx.alice_mb.uuid, "drafts")
    refute_received {:outbound, _, _, _}

    {:ok, reopened, _html} =
      live(as_alice(ctx), "/en/admin/inbox/compose?draft=#{draft.uuid}")

    assert has_element?(
             reopened,
             "#compose-identity option[selected][value='#{ctx.common.uuid}']"
           )

    assert has_element?(reopened, "input[name='to'][value='client@example.com']")
  end
end
