defmodule PhoenixKitInbox.Web.InboxExternalTest do
  @moduledoc """
  External recipients in the reading pane: their status, Bcc for the sender
  only, "Retry" — and a forged retry.
  """

  use PhoenixKitInbox.LiveCase

  import Ecto.Query, only: [from: 2]

  alias PhoenixKitInbox.External
  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Schemas.ExternalRecipient
  alias PhoenixKitInbox.Test.Repo

  @external ["inbox", "inbox.send_external"]

  setup :outbound_setup

  setup %{conn: conn} do
    enable_inbox!()
    admin = user_fixture()
    alice = user_fixture()
    bob = user_fixture()
    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)
    smtp = mail_integration_fixture(:system, username: "noreply@company.test")
    # The role that sends externally; the common sender is opened to it.
    senders = grant_role!(alice, @external)

    {:ok, common} =
      Identities.create_shared(scope_for(admin, ["inbox", "inbox.manage_shared"]), %{
        "label" => "Common",
        "integration_uuid" => smtp
      })

    :ok = External.subscribe(alice_mb.uuid)
    outbound_result({:error, :smtp_down})

    {:ok, message} =
      Messages.send_message(scope_for(alice, @external, [senders]), alice_mb, %{
        "to" => "@#{bob.username}, client@example.com",
        "bcc" => "hidden@example.com",
        "subject" => "Offer",
        "body" => "Hello",
        "identity_uuid" => common.uuid
      })

    await_external(message.uuid)
    outbound_result({:ok, %{id: "ok"}})
    assert_received {:outbound, _, _, _}

    %{
      conn: conn,
      alice: alice,
      bob: bob,
      alice_mb: alice_mb,
      bob_mb: bob_mb,
      senders: senders,
      message: message
    }
  end

  defp open(ctx, user, mailbox, folder, permissions \\ @external) do
    conn =
      put_test_scope(ctx.conn, scope_for(user, permissions, [ctx.senders]))

    {:ok, view, _html} =
      live(
        conn,
        "/en/admin/inbox?mailbox=#{mailbox.uuid}&folder=#{folder}&message=#{ctx.message.uuid}"
      )

    view
  end

  defp chip(view, address) do
    view
    |> element("#external-recipients span[id^='external-']", address)
    |> render()
  end

  test "the sender sees every external recipient with its status", ctx do
    view = open(ctx, ctx.alice, ctx.alice_mb, "sent")

    assert chip(view, "client@example.com") =~ "not delivered"
    assert chip(view, "hidden@example.com") =~ "bcc"
    refute has_element?(view, "#retry-external")
  end

  test "a recipient sees the To and Cc addresses — no Bcc, no status, no Retry", ctx do
    emails_module_enabled!()
    view = open(ctx, ctx.bob, ctx.bob_mb, "inbox")

    assert has_element?(view, "#external-recipients", "client@example.com")
    refute has_element?(view, "#external-recipients", "hidden@example.com")
    refute has_element?(view, "#external-recipients", "not delivered")
    refute has_element?(view, "#external-recipients [title]")
    refute has_element?(view, "#retry-external")
  end

  test "Retry, offered while the email log says it all failed, sends again", ctx do
    emails_module_enabled!()
    email_log_fixture(%{"inbox_message_uuid" => ctx.message.uuid}, "failed")
    view = open(ctx, ctx.alice, ctx.alice_mb, "sent")

    view |> element("#retry-external") |> render_click()
    await_external(ctx.message.uuid)

    assert_received {:outbound, _, _, _}
    assert Enum.all?(External.list(ctx.message.uuid), &(&1.status == "sent"))

    # The update reaches the open page.
    send(view.pid, {:inbox_external_updated, ctx.message.uuid})
    assert chip(view, "client@example.com") =~ "sent"
    refute has_element?(view, "#retry-external")
  end

  test "no Retry once the email log has a row that went out", ctx do
    emails_module_enabled!()
    email_log_fixture(%{"inbox_message_uuid" => ctx.message.uuid}, "sent")

    view = open(ctx, ctx.alice, ctx.alice_mb, "sent")
    refute has_element?(view, "#retry-external")
  end

  test "a forged retry from a recipient's copy sends nothing", ctx do
    emails_module_enabled!()
    email_log_fixture(%{"inbox_message_uuid" => ctx.message.uuid}, "failed")
    view = open(ctx, ctx.bob, ctx.bob_mb, "inbox")

    html = render_click(view, "retry_external", %{"uuid" => ctx.message.uuid})

    assert html =~ "Message not found."
    refute_received {:outbound, _, _, _}
    assert Enum.all?(External.list(ctx.message.uuid), &(&1.status == "failed"))
  end

  test "a send pending for over 15 minutes reads as unknown", ctx do
    long_ago = DateTime.utc_now() |> DateTime.add(-20 * 60) |> DateTime.truncate(:second)

    Repo.update_all(
      from(r in ExternalRecipient, where: r.message_uuid == ^ctx.message.uuid),
      set: [status: "pending", attempted_at: nil, inserted_at: long_ago]
    )

    view = open(ctx, ctx.alice, ctx.alice_mb, "sent")
    assert chip(view, "client@example.com") =~ "unknown — check the email log"
  end
end
