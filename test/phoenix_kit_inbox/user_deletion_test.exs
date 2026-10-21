defmodule PhoenixKitInbox.UserDeletionTest do
  @moduledoc """
  Deleting a user keeps the correspondence (V02 foreign keys) and leaves no
  live mailbox without an owner (`PhoenixKitInbox.before_user_delete/1`).
  Users are deleted through core's `Auth.delete_user/2`, which runs every
  module's hook first.
  """

  use PhoenixKitInbox.DataCase, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Schemas.Mailbox
  alias PhoenixKitInbox.Schemas.MailboxGrant
  alias PhoenixKitInbox.Schemas.Message

  setup do
    leaver = user_fixture()
    stayer = user_fixture()
    {:ok, leaver_mb} = Mailboxes.ensure_user_mailbox(leaver)
    {:ok, stayer_mb} = Mailboxes.ensure_user_mailbox(stayer)

    admin = user_fixture()
    grant_role!(admin, [], name: "Owner")

    %{leaver: leaver, stayer: stayer, leaver_mb: leaver_mb, stayer_mb: stayer_mb, admin: admin}
  end

  defp delete!(ctx, user) do
    assert {:ok, _} = Auth.delete_user(user, %{current_user: ctx.admin})
  end

  test "messages the user sent, and every recipient's copy, survive", ctx do
    {:ok, sent} =
      Messages.send_message(ctx.leaver_mb, ctx.leaver.uuid, %{
        "to" => ctx.stayer.email,
        "subject" => "Before I go"
      })

    delete!(ctx, ctx.leaver)

    assert %Message{status: "sent", sender_user_uuid: nil} = Repo.get(Message, sent.uuid)
    assert [%{message: %{uuid: uuid}}] = Messages.list_folder(ctx.stayer_mb.uuid, "inbox")
    assert uuid == sent.uuid
    # Who wrote it is still readable.
    assert Repo.get(Message, sent.uuid).metadata["sender"]["email"] == ctx.leaver.email
  end

  test "messages the user received survive in their mailbox", ctx do
    {:ok, received} =
      Messages.send_message(ctx.stayer_mb, ctx.stayer.uuid, %{
        "to" => ctx.leaver.email,
        "subject" => "For you"
      })

    delete!(ctx, ctx.leaver)

    assert [%{message: %{uuid: uuid}}] = Messages.list_folder(ctx.leaver_mb.uuid, "inbox")
    assert uuid == received.uuid
  end

  test "the personal mailbox is archived and left without an owner", ctx do
    delete!(ctx, ctx.leaver)

    assert %Mailbox{status: "archived", owner_uuid: nil, kind: "user"} =
             Repo.get(Mailbox, ctx.leaver_mb.uuid)
  end

  test "a shared mailbox passes to its oldest admin grantee", ctx do
    shared = shared_mailbox_fixture(ctx.leaver, %{name: "Handover"})
    newer_admin = user_fixture()
    grant_fixture(shared, ctx.stayer, "admin")
    grant_fixture(shared, user_fixture(), "write")
    # Make the grant order unambiguous regardless of clock resolution.
    Repo.update_all(
      from(g in MailboxGrant, where: g.mailbox_uuid == ^shared.uuid),
      set: [inserted_at: ~U[2026-01-01 00:00:00Z]]
    )

    grant_fixture(shared, newer_admin, "admin")

    delete!(ctx, ctx.leaver)

    mailbox = Repo.get(Mailbox, shared.uuid)
    assert mailbox.status == "active"
    assert mailbox.owner_uuid == ctx.stayer.uuid
    # The new owner holds admin by ownership; the grant row would be noise.
    refute Repo.get_by(MailboxGrant, mailbox_uuid: shared.uuid, user_uuid: ctx.stayer.uuid)
    assert Mailboxes.access_level(mailbox, newer_admin.uuid) == "admin"
  end

  test "a deactivated admin grantee is passed over for the next active one", ctx do
    shared = shared_mailbox_fixture(ctx.leaver, %{name: "Skip the sleeper"})
    sleeper = user_fixture(%{is_active: false})
    grant_fixture(shared, sleeper, "admin")

    Repo.update_all(
      from(g in MailboxGrant, where: g.mailbox_uuid == ^shared.uuid),
      set: [inserted_at: ~U[2026-01-01 00:00:00Z]]
    )

    grant_fixture(shared, ctx.stayer, "admin")

    delete!(ctx, ctx.leaver)

    assert %Mailbox{status: "active", owner_uuid: owner} = Repo.get(Mailbox, shared.uuid)
    assert owner == ctx.stayer.uuid
  end

  test "a shared mailbox whose only admin grantee is deactivated is archived", ctx do
    shared = shared_mailbox_fixture(ctx.leaver, %{name: "Nobody awake"})
    grant_fixture(shared, user_fixture(%{is_active: false}), "admin")

    delete!(ctx, ctx.leaver)

    assert %Mailbox{status: "archived", owner_uuid: nil} = Repo.get(Mailbox, shared.uuid)
  end

  test "a shared mailbox with no admin grantee is archived", ctx do
    shared = shared_mailbox_fixture(ctx.leaver, %{name: "Last one out"})
    grant_fixture(shared, ctx.stayer, "write")

    delete!(ctx, ctx.leaver)

    assert %Mailbox{status: "archived", owner_uuid: nil} = Repo.get(Mailbox, shared.uuid)
  end

  test "the foreign keys alone keep the mail when no hook runs", ctx do
    {:ok, sent} =
      Messages.send_message(ctx.leaver_mb, ctx.leaver.uuid, %{
        "to" => ctx.stayer.email,
        "subject" => "Hookless"
      })

    Repo.delete!(ctx.leaver)

    assert Repo.get(Message, sent.uuid)
    assert %Mailbox{owner_uuid: nil} = Repo.get(Mailbox, ctx.leaver_mb.uuid)
  end
end
