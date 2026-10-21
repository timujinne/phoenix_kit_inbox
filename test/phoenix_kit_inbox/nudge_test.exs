defmodule PhoenixKitInbox.NudgeTest do
  @moduledoc """
  The new-message email nudge: only through `Outbound`, only from the nudge
  sender the module's settings name — never core's default integration.
  """

  use PhoenixKitInbox.DataCase, async: false

  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Notify
  alias PhoenixKitInbox.Test.OutboundFilters

  setup :outbound_setup

  setup do
    enable_inbox!()
    admin = user_fixture()
    alice = user_fixture()
    bob = user_fixture(%{email: "bob@company.test"})
    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)
    smtp = mail_integration_fixture(:system, username: "notices@company.test")
    manager = scope_for(admin, ["inbox", "inbox.manage_shared"])

    {:ok, notices} =
      Identities.create_shared(manager, %{
        "label" => "Notices",
        "from_name" => "Company notices",
        "integration_uuid" => smtp
      })

    {:ok, _} = PhoenixKitInbox.set_email_nudges(true)

    %{
      alice: alice,
      bob: bob,
      alice_mb: alice_mb,
      smtp: smtp,
      notices: notices,
      manager: manager
    }
  end

  defp send_to_bob(ctx) do
    {:ok, message} =
      Messages.send_message(scope_for(ctx.alice), ctx.alice_mb, %{
        "to" => "@" <> ctx.bob.username,
        "subject" => "Lunch?"
      })

    message
  end

  test "goes from the nudge sender, through Outbound, to the recipient's email", ctx do
    {:ok, _} = PhoenixKitInbox.set_nudge_identity(ctx.manager, ctx.notices.uuid)

    message = send_to_bob(ctx)

    assert_receive {:outbound, email, integration, opts}, 2_000
    assert integration == ctx.smtp
    assert email.to == [{"", "bob@company.test"}]
    assert email.from == {"Company notices", "notices@company.test"}
    assert email.subject == "New message: Lunch?"
    assert opts[:skip_queue] == true and opts[:queue] == false
    assert opts[:message_tags]["inbox_kind"] == "nudge"
    assert opts[:message_tags]["inbox_message_uuid"] == message.uuid
    assert Notify.email_nudges_available?()
  end

  test "without a nudge sender there is no nudge", ctx do
    send_to_bob(ctx)

    refute_receive {:outbound, _, _, _}, 200
    refute Notify.email_nudges_available?()
  end

  test "with external sending closed there is no nudge", ctx do
    {:ok, _} = PhoenixKitInbox.set_nudge_identity(ctx.manager, ctx.notices.uuid)
    outbound_filter(nil)

    send_to_bob(ctx)

    refute_receive {:outbound, _, _, _}, 200
    refute Notify.email_nudges_available?()
  end

  test "the host filter applies to nudges too", ctx do
    {:ok, _} = PhoenixKitInbox.set_nudge_identity(ctx.manager, ctx.notices.uuid)
    outbound_filter({OutboundFilters, :redirect})

    send_to_bob(ctx)

    assert_receive {:outbound, %{to: [{"", "redirect@test.example"}]}, _, _}, 2_000
  end

  test "with external sending closed the nudge sender is not even checked", ctx do
    {:ok, _} = PhoenixKitInbox.set_nudge_identity(ctx.manager, ctx.notices.uuid)
    :ok = PhoenixKit.Integrations.remove_connection(ctx.smtp, nil, owner: :system)
    outbound_filter(nil)

    send_to_bob(ctx)

    assert Repo.get(PhoenixKitInbox.Schemas.Identity, ctx.notices.uuid).status == "active"
  end

  test "with the nudge setting off there is no nudge", ctx do
    {:ok, _} = PhoenixKitInbox.set_nudge_identity(ctx.manager, ctx.notices.uuid)
    {:ok, _} = PhoenixKitInbox.set_email_nudges(false)

    send_to_bob(ctx)

    refute_receive {:outbound, _, _, _}, 200
  end

  test "a broken nudge sender sends nothing", ctx do
    {:ok, _} = PhoenixKitInbox.set_nudge_identity(ctx.manager, ctx.notices.uuid)
    :ok = PhoenixKit.Integrations.remove_connection(ctx.smtp, nil, owner: :system)

    send_to_bob(ctx)

    refute_receive {:outbound, _, _, _}, 200
  end

  describe "set_nudge_identity/2" do
    test "needs inbox.manage_shared", ctx do
      assert PhoenixKitInbox.set_nudge_identity(scope_for(ctx.alice), ctx.notices.uuid) ==
               {:error, :forbidden}

      assert PhoenixKitInbox.nudge_identity_uuid() == nil
    end

    test "takes a shared identity only", ctx do
      own = mail_integration_fixture({:user, ctx.alice.uuid})

      {:ok, personal} =
        Identities.create_personal(scope_for(ctx.alice), %{
          "label" => "Mine",
          "integration_uuid" => own
        })

      assert PhoenixKitInbox.set_nudge_identity(ctx.manager, personal.uuid) ==
               {:error, :forbidden}

      assert PhoenixKitInbox.set_nudge_identity(ctx.manager, Ecto.UUID.generate()) ==
               {:error, :not_found}

      assert {:ok, _} = PhoenixKitInbox.set_nudge_identity(ctx.manager, ctx.notices.uuid)
      assert PhoenixKitInbox.nudge_identity_uuid() == ctx.notices.uuid

      assert {:ok, _} = PhoenixKitInbox.set_nudge_identity(ctx.manager, nil)
      assert PhoenixKitInbox.nudge_identity_uuid() == nil
    end
  end

  test "resolve_system/1 refuses a personal identity", ctx do
    own = mail_integration_fixture({:user, ctx.alice.uuid})

    {:ok, personal} =
      Identities.create_personal(scope_for(ctx.alice), %{
        "label" => "Mine",
        "integration_uuid" => own
      })

    assert Identities.resolve_system(personal.uuid) == {:error, :forbidden}
    assert {:ok, %{from_name: "Company notices"}} = Identities.resolve_system(ctx.notices.uuid)
  end
end
