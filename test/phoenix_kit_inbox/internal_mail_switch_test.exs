defmodule PhoenixKitInbox.InternalMailSwitchTest do
  @moduledoc """
  The switch for mail inside the application: what a send, the route lookup
  and the suggestions do when it is off, and that nothing already delivered or
  sent outside changes.
  """

  use PhoenixKitInbox.DataCase, async: false

  alias PhoenixKitInbox.External
  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.RecipientSource
  alias PhoenixKitInbox.Schemas.Mailbox
  alias PhoenixKitInbox.Schemas.Message

  @external ["inbox", "inbox.send_external"]
  @user "0190f0f0-0000-7000-8000-0000000000aa"

  defmodule Source do
    @moduledoc false
    @behaviour PhoenixKitInbox.RecipientSource

    @impl true
    def suggest(_scope, context, _query), do: Map.fetch!(context, :entries)
  end

  setup :outbound_setup
  setup :internal_mail_setup

  setup do
    enable_inbox!()
    admin = user_fixture()
    alice = user_fixture(%{first_name: "Alice", last_name: "Smith"})
    bob = user_fixture(%{first_name: "Bob"})
    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)
    desk = shared_mailbox_fixture(admin, %{name: "Desk", address: "desk@company.test"})
    plain = shared_mailbox_fixture(admin, %{name: "Plain"})
    grant_fixture(desk, alice, "write")
    smtp = mail_integration_fixture(:system, username: "noreply@company.test")
    senders = grant_role!(alice, @external)

    {:ok, common} =
      Identities.create_shared(scope_for(admin, ["inbox", "inbox.manage_shared"]), %{
        "label" => "Common",
        "integration_uuid" => smtp
      })

    :ok = External.subscribe(alice_mb.uuid)

    %{
      alice: alice,
      bob: bob,
      alice_mb: alice_mb,
      bob_mb: bob_mb,
      desk: desk,
      plain: plain,
      common: common,
      outside: scope_for(alice, @external, [senders]),
      inside_only: scope_for(alice)
    }
  end

  defp off!, do: {:ok, _} = PhoenixKitInbox.set_internal_enabled(false)

  defp send_to(ctx, to, extra \\ %{}, scope \\ :outside) do
    # Only a sender with the outside right has an identity to send as.
    identity = if scope == :outside, do: %{"identity_uuid" => ctx.common.uuid}, else: %{}

    ctx
    |> Map.fetch!(scope)
    |> Messages.send_message(
      ctx.alice_mb,
      Enum.reduce(
        [identity, extra],
        %{"to" => to, "subject" => "Hello", "body" => "Body"},
        &Map.merge(&2, &1)
      )
    )
    |> tap(fn
      {:ok, %Message{external_status: :pending} = message} -> await_external(message.uuid)
      _ -> :ok
    end)
  end

  describe "the setting" do
    test "is on when nothing was saved and nothing configured" do
      assert PhoenixKitInbox.internal_enabled?()
    end

    test "is kept: off, then on again" do
      off!()
      refute PhoenixKitInbox.internal_enabled?()

      assert {:ok, _} = PhoenixKitInbox.set_internal_enabled(true)
      assert PhoenixKitInbox.internal_enabled?()
    end

    test "a saved setting wins over the host's default" do
      Application.put_env(:phoenix_kit_inbox, :internal_mail_default, false)
      on_exit(fn -> Application.delete_env(:phoenix_kit_inbox, :internal_mail_default) end)

      refute PhoenixKitInbox.internal_enabled?()
      assert {:ok, _} = PhoenixKitInbox.set_internal_enabled(true)
      assert PhoenixKitInbox.internal_enabled?()
    end

    test "is shown in the module's config" do
      assert %{internal_mail: true} = PhoenixKitInbox.get_config()
      off!()
      assert %{internal_mail: false} = PhoenixKitInbox.get_config()
    end
  end

  describe "off: sending" do
    test "an inside-only handle is refused and nothing is written", ctx do
      off!()

      assert send_to(ctx, "@#{ctx.bob.username}") == {:error, :internal_mail_disabled}

      assert Messages.list_folder(ctx.bob_mb.uuid, "inbox") == []
      assert Messages.list_folder(ctx.alice_mb.uuid, "sent") == []
      assert Messages.list_folder(ctx.alice_mb.uuid, "outbox") == []
      assert Repo.aggregate(Message, :count) == 0
    end

    test "so is a shared mailbox's name or slug, also next to an outside address", ctx do
      off!()

      for to <- ["Plain", ctx.plain.slug, "@#{ctx.bob.username}, client@example.com"] do
        assert send_to(ctx, to) == {:error, :internal_mail_disabled}
      end

      assert Repo.aggregate(Message, :count) == 0
    end

    test "a name that is nobody's is unknown, as before", ctx do
      off!()
      assert send_to(ctx, "nobody-at-all") == {:error, {:unknown_recipients, ["nobody-at-all"]}}
    end

    test "the three-argument form refuses it too", ctx do
      off!()

      assert Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
               "to" => "@#{ctx.bob.username}",
               "subject" => "Hi",
               "body" => "Hi"
             }) == {:error, :internal_mail_disabled}
    end

    test "a member addressed by their email goes as an outside email", ctx do
      off!()

      assert {:ok, %Message{external_status: :pending} = message} = send_to(ctx, ctx.bob.email)

      assert Messages.list_folder(ctx.bob_mb.uuid, "inbox") == []
      assert [%{address: address, status: "sent"}] = External.list(message.uuid)
      assert address == ctx.bob.email
      assert_received {:outbound, %{to: [{_, ^address}]}, _, _}
      assert [_] = Messages.list_folder(ctx.alice_mb.uuid, "sent")
    end

    test "a shared mailbox addressed by its email is an outside address too", ctx do
      off!()

      assert {:ok, message} = send_to(ctx, "desk@company.test")

      assert Messages.list_folder(ctx.desk.uuid, "inbox") == []
      assert [%{address: "desk@company.test"}] = External.list(message.uuid)
    end

    test "needs the right to write outside, and says so for a colleague's address", ctx do
      off!()

      assert send_to(ctx, ctx.bob.email, %{}, :inside_only) == {:error, :external_not_allowed}

      assert Messages.list_folder(ctx.bob_mb.uuid, "inbox") == []
    end

    test "a draft naming only an inside handle can't be sent, and stays a draft", ctx do
      assert {:ok, draft} =
               Messages.save_draft(ctx.outside, ctx.alice_mb, %{
                 "to" => "@#{ctx.bob.username}",
                 "subject" => "Later",
                 "body" => "Body"
               })

      off!()

      assert send_to(ctx, "@#{ctx.bob.username}", %{"uuid" => draft.uuid}) ==
               {:error, :internal_mail_disabled}

      assert [%{message: %{uuid: uuid}}] = Messages.list_folder(ctx.alice_mb.uuid, "drafts")
      assert uuid == draft.uuid
    end
  end

  describe "off: lookups and suggestions" do
    test "resolve_recipient_routes/2 answers :email, with `refused:` on what the send refuses",
         ctx do
      addresses = ["@#{ctx.bob.username}", ctx.bob.email, "desk@company.test", ctx.plain.slug]

      assert [%{route: :internal} | _] =
               Messages.resolve_recipient_routes(ctx.inside_only, addresses)

      off!()

      routes = Messages.resolve_recipient_routes(ctx.inside_only, addresses)
      assert Enum.map(routes, & &1.address) == addresses
      assert Enum.all?(routes, &(&1.mailbox_uuid == nil))

      # What the send refuses carries `refused:`; the route stays :email.
      assert Enum.map(routes, & &1.route) == [:email, :email, :email, :email]

      assert Enum.map(routes, &Map.get(&1, :refused)) ==
               [:internal_mail_disabled, nil, nil, :internal_mail_disabled]
    end

    test "nobody is suggested, and a reply is addressed by email", ctx do
      assert [_ | _] = Mailboxes.search_recipients(ctx.alice.uuid, "")
      assert Mailboxes.recipient_handle(ctx.bob_mb) == "@#{ctx.bob.username}"
      assert Mailboxes.recipient_handle(ctx.plain) == (ctx.plain.address || ctx.plain.slug)

      off!()

      assert Mailboxes.search_recipients(ctx.alice.uuid, "") == []
      assert Mailboxes.recipient_handle(ctx.bob_mb) == ctx.bob.email
      assert Mailboxes.recipient_handle(ctx.desk) == "desk@company.test"
      assert Mailboxes.recipient_handle(ctx.plain) == nil
      # Granting a shared mailbox is not mail.
      assert Mailboxes.search_users(ctx.alice.uuid, "") != []
    end
  end

  describe "off: what stays" do
    test "letters delivered before stay readable and can be filed", ctx do
      assert {:ok, message} = send_to(ctx, "@#{ctx.bob.username}", %{}, :inside_only)
      off!()

      assert [%{message: %{uuid: uuid}}] = Messages.list_folder(ctx.bob_mb.uuid, "inbox")
      assert uuid == message.uuid
      assert {:ok, _} = Messages.fetch_for_mailbox(ctx.bob_mb.uuid, message.uuid)
      assert [_] = Messages.list_folder(ctx.alice_mb.uuid, "sent")
    end

    test "an outside email, a recorded send and the shared mailbox's own mail go as before",
         ctx do
      off!()

      assert {:ok, message} = send_to(ctx, "client@example.com")
      assert [%{status: "sent"}] = External.list(message.uuid)

      assert {:ok, _} =
               Messages.record_sent(ctx.outside, ctx.alice_mb, %{
                 "subject" => "Recorded",
                 "body" => "Body",
                 "external_recipients" => [%{"address" => "client@example.com"}]
               })

      assert [_, _] = Messages.list_folder(ctx.alice_mb.uuid, "sent")
    end

    test "record_sent/4 takes a member's address as an outside address, and makes no mailbox",
         ctx do
      stranger = user_fixture()
      off!()

      assert {:ok, message} =
               Messages.record_sent(ctx.outside, ctx.alice_mb, %{
                 "subject" => "Recorded",
                 "body" => "Body",
                 "external_recipients" => [%{"address" => stranger.email}]
               })

      assert [%{address: address}] = External.list(message.uuid)
      assert address == stranger.email
      assert Repo.get_by(Mailbox, owner_uuid: stranger.uuid, kind: "user") == nil
    end

    test "record_sent/4 still refuses it while internal mail is on", ctx do
      stranger = user_fixture()

      assert {:error, {:internal_recipients, [_]}} =
               Messages.record_sent(ctx.outside, ctx.alice_mb, %{
                 "subject" => "Recorded",
                 "body" => "Body",
                 "external_recipients" => [%{"address" => stranger.email}]
               })
    end

    test "turned on again, inside delivery is back", ctx do
      off!()
      assert {:ok, _} = PhoenixKitInbox.set_internal_enabled(true)

      assert {:ok, _} = send_to(ctx, "@#{ctx.bob.username}", %{}, :inside_only)
      assert [_] = Messages.list_folder(ctx.bob_mb.uuid, "inbox")
    end
  end

  describe "recipient sources while it is off" do
    setup do
      off!()

      entries = [
        %{address: "@bob", label: "Bob", route: :internal},
        %{user: @user, label: "Carol", route: :internal},
        %{address: "dave@example.com", label: "Dave", route: :email}
      ]

      %{context: %{entries: entries}}
    end

    test "an inside entry with an account is offered by email, one with only a handle is not",
         ctx do
      assert [
               %{user: @user, route: :email, label: "Carol"},
               %{address: "dave@example.com", route: :email}
             ] = RecipientSource.suggest_all([Source], nil, ctx.context, "x")
    end

    test "nothing is changed while it is on", ctx do
      assert {:ok, _} = PhoenixKitInbox.set_internal_enabled(true)

      assert [
               %{address: "@bob", route: :internal},
               %{user: @user, route: :internal},
               %{address: "dave@example.com", route: :email}
             ] = RecipientSource.suggest_all([Source], nil, ctx.context, "x")
    end
  end
end
