defmodule PhoenixKitInbox.PreviewRoutesTest do
  @moduledoc """
  What a host can ask before it sends: the email as the outbound filter would
  leave it (`Outbound.preview/2`, nothing sent) and the way each address would
  travel (`Messages.resolve_recipient_routes/2`, the send path's own lookup).
  """

  use PhoenixKitInbox.DataCase, async: false

  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Outbound
  alias PhoenixKitInbox.Schemas.ExternalRecipient
  alias PhoenixKitInbox.Schemas.Message
  alias PhoenixKitInbox.Test.OutboundFilters

  setup :outbound_setup

  defp email do
    Swoosh.Email.new()
    |> Swoosh.Email.from({"Desk", "desk@company.test"})
    |> Swoosh.Email.to({"Client", "client@example.com"})
    |> Swoosh.Email.reply_to("desk@company.test")
    |> Swoosh.Email.subject("Offer")
    |> Swoosh.Email.text_body("Text")
  end

  defp context(extra \\ %{}) do
    Map.merge(
      %{
        kind: :message,
        integration_uuid: "0190f0f0-0000-7000-8000-000000000001",
        user_uuid: "0190f0f0-0000-7000-8000-0000000000aa"
      },
      extra
    )
  end

  describe "Outbound.preview/2" do
    test "preview applies the filter without delivering" do
      outbound_filter({OutboundFilters, :redirect})

      assert {:ok, %Swoosh.Email{} = previewed} = Outbound.preview(email(), context())

      # Addressing as the host's filter leaves it; the rest as built.
      assert previewed.to == [{"", "redirect@test.example"}]
      assert previewed.bcc == [{"", "bcc-redirect@test.example"}]
      assert previewed.reply_to == {"", "reply-redirect@test.example"}
      assert previewed.from == {"Desk", "desk@company.test"}
      assert previewed.subject == "Offer"
      refute_received {:outbound, _, _, _}
    end

    test "the filter is told it is a preview; a real send is not" do
      outbound_filter({OutboundFilters, :record_context})

      assert {:ok, _} = Outbound.preview(email(), context())
      assert_received {:filter_context, %{preview: true, kind: :message}}

      assert {:ok, _} = Outbound.deliver(email(), context())
      assert_received {:filter_context, delivered}
      refute Map.get(delivered, :preview)
      assert_received {:outbound, _, _, _}
    end

    test "preview propagates a filter refusal" do
      outbound_filter({OutboundFilters, :refuse})

      assert Outbound.preview(email(), context()) ==
               {:error, {:filter_refused, :no_test_address}}

      refute_received {:outbound, _, _, _}
    end

    test "a filter that fails refuses the preview too" do
      outbound_filter({OutboundFilters, :raises})

      assert Outbound.preview(email(), context()) == {:error, :filter_failed}
    end

    test "preview is closed like a send: nothing to show where nothing could go" do
      {:ok, _} = PhoenixKitInbox.set_external_enabled(false)
      assert Outbound.preview(email(), context()) == {:error, :external_disabled}

      {:ok, _} = PhoenixKitInbox.set_external_enabled(true)
      outbound_filter(nil)
      assert Outbound.preview(email(), context()) == {:error, :external_disabled}
    end

    test "an email left with no recipient is not previewed either" do
      outbound_filter(:none)
      bare = %{email() | to: [], cc: [], bcc: []}

      assert Outbound.preview(bare, context()) == {:error, :no_recipients}
    end

    test "preview writes nothing and never reaches the transport" do
      outbound_filter({OutboundFilters, :redirect})
      messages = Repo.aggregate(Message, :count)
      externals = Repo.aggregate(ExternalRecipient, :count)
      email_logs = Repo.aggregate("phoenix_kit_email_logs", :count)

      assert {:ok, _} = Outbound.preview(email(), context())

      assert Repo.aggregate(Message, :count) == messages
      assert Repo.aggregate(ExternalRecipient, :count) == externals
      assert Repo.aggregate("phoenix_kit_email_logs", :count) == email_logs
      refute_received {:outbound, _, _, _}
    end
  end

  describe "Messages.resolve_recipient_routes/2" do
    setup do
      enable_inbox!()
      alice = user_fixture()
      bob = user_fixture(%{email: "bob@company.test"})
      {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)
      admin = user_fixture()
      desk = shared_mailbox_fixture(admin, %{name: "Desk", address: "desk@company.test"})
      %{scope: scope_for(alice), bob: bob, bob_mb: bob_mb, desk: desk}
    end

    test "member address routes internal; unknown routes email", ctx do
      routes =
        Messages.resolve_recipient_routes(ctx.scope, [
          "bob@company.test",
          "@" <> ctx.bob.username,
          "desk@company.test",
          "client@example.com"
        ])

      assert routes == [
               %{address: "bob@company.test", route: :internal, mailbox_uuid: ctx.bob_mb.uuid},
               %{
                 address: "@" <> ctx.bob.username,
                 route: :internal,
                 mailbox_uuid: ctx.bob_mb.uuid
               },
               %{address: "desk@company.test", route: :internal, mailbox_uuid: ctx.desk.uuid},
               %{address: "client@example.com", route: :email, mailbox_uuid: nil}
             ]
    end

    test "it answers as the send does: what it calls internal is delivered inside", ctx do
      alice_scope = ctx.scope
      {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice_scope.user)

      [%{route: :internal}] = Messages.resolve_recipient_routes(alice_scope, ["bob@company.test"])

      assert {:ok, message} =
               Messages.send_message(alice_scope, alice_mb, %{
                 "to" => "bob@company.test",
                 "subject" => "Inside"
               })

      assert message.external_status == :none
      assert [_] = Messages.list_folder(ctx.bob_mb.uuid, "inbox")
    end

    test "spelling does not matter, the order and the address as given do", ctx do
      assert [
               %{address: "BOB@Company.test", route: :internal},
               %{address: "Client@Example.com", route: :email}
             ] =
               Messages.resolve_recipient_routes(ctx.scope, [
                 "BOB@Company.test",
                 "Client@Example.com"
               ])
    end

    test "text that names nobody and is no address is not internal", ctx do
      assert [%{address: "nobody-here", route: :email, mailbox_uuid: nil}] =
               Messages.resolve_recipient_routes(ctx.scope, ["nobody-here"])
    end

    test "no addresses, no routes; non-text entries are skipped", ctx do
      assert Messages.resolve_recipient_routes(ctx.scope, []) == []
      assert Messages.resolve_recipient_routes(ctx.scope, [nil, 5, :bob]) == []
    end

    test "it writes no message", ctx do
      before = Repo.aggregate(Message, :count)
      Messages.resolve_recipient_routes(ctx.scope, ["bob@company.test", "client@example.com"])
      assert Repo.aggregate(Message, :count) == before
    end
  end
end
