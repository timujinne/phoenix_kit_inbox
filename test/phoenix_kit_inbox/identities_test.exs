defmodule PhoenixKitInbox.IdentitiesTest do
  use PhoenixKitInbox.DataCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Schemas.Identity

  @manage ["inbox", "inbox.manage_shared"]
  @external ["inbox", "inbox.send_external"]

  setup do
    enable_inbox!()
    admin = user_fixture(%{first_name: "Ada", last_name: "Admin"})
    alice = user_fixture(%{first_name: "Alice", last_name: "Smith"})
    bob = user_fixture(%{first_name: "Bob", last_name: "Jones"})
    desk = shared_mailbox_fixture(admin, %{name: "Desk", address: "desk@company.test"})
    system_smtp = mail_integration_fixture(:system, username: "desk@company.test")

    %{admin: admin, alice: alice, bob: bob, desk: desk, system_smtp: system_smtp}
  end

  defp shared!(ctx, attrs) do
    {:ok, identity} =
      Identities.create_shared(scope_for(ctx.admin, @manage), Map.new(attrs))

    identity
  end

  describe "create_shared/2" do
    test "needs inbox.manage_shared — a forged submit without it is refused", ctx do
      attrs = %{"label" => "Desk", "integration_uuid" => ctx.system_smtp}

      assert {:error, :forbidden} = Identities.create_shared(scope_for(ctx.alice), attrs)

      assert {:error, :forbidden} =
               Identities.create_shared(scope_for(ctx.alice, @external), attrs)

      assert Repo.aggregate(Identity, :count) == 0
    end

    test "binds a system mail integration to a shared mailbox", ctx do
      assert {:ok, identity} =
               Identities.create_shared(scope_for(ctx.admin, @manage), %{
                 "label" => "Desk",
                 "from_name" => "Company Desk",
                 "integration_uuid" => ctx.system_smtp,
                 "mailbox_uuid" => ctx.desk.uuid
               })

      assert identity.kind == "shared"
      assert identity.mailbox_uuid == ctx.desk.uuid
      assert identity.owner_uuid == nil
      assert identity.status == "active"
      assert identity.integration_uuid == ctx.system_smtp
    end

    test "without a mailbox it is the common sender for personal mailboxes", ctx do
      identity = shared!(ctx, label: "Common", integration_uuid: ctx.system_smtp)

      assert identity.mailbox_uuid == nil
      assert identity.kind == "shared"
    end

    test "kind, owner and status from the form are ignored", ctx do
      identity =
        shared!(ctx, %{
          "label" => "Desk",
          "integration_uuid" => ctx.system_smtp,
          "kind" => "personal",
          "owner_uuid" => ctx.alice.uuid,
          "status" => "broken"
        })

      assert identity.kind == "shared"
      assert identity.owner_uuid == nil
      assert identity.status == "active"
    end

    test "refuses someone's personal integration", ctx do
      personal = mail_integration_fixture({:user, ctx.alice.uuid})

      assert {:error, {:integration_unusable, :owner_mismatch}} =
               Identities.create_shared(scope_for(ctx.admin, @manage), %{
                 "label" => "Stolen",
                 "integration_uuid" => personal
               })
    end

    test "refuses an integration that cannot send mail", ctx do
      ai = mail_integration_fixture(:system, provider: "openrouter")

      assert {:error, {:integration_unusable, :not_mail_provider}} =
               Identities.create_shared(scope_for(ctx.admin, @manage), %{
                 "label" => "AI",
                 "integration_uuid" => ai
               })
    end

    test "refuses a mail integration with no login address to send from", ctx do
      brevo = mail_integration_fixture(:system, provider: "brevo_api")
      no_login = mail_integration_fixture(:system, username: "relay-user")

      for uuid <- [brevo, no_login] do
        assert {:error, {:integration_unusable, :no_from_address}} =
                 Identities.create_shared(scope_for(ctx.admin, @manage), %{
                   "label" => "No login",
                   "integration_uuid" => uuid
                 })
      end
    end

    test "refuses a missing or unconnected integration", ctx do
      unconnected = mail_integration_fixture(:system, setup: false)

      assert {:error, {:integration_unusable, :not_connected}} =
               Identities.create_shared(scope_for(ctx.admin, @manage), %{
                 "label" => "Nope",
                 "integration_uuid" => unconnected
               })

      for uuid <- [Ecto.UUID.generate(), "not-a-uuid", nil] do
        assert {:error, {:integration_unusable, :integration_missing}} =
                 Identities.create_shared(scope_for(ctx.admin, @manage), %{
                   "label" => "Nope",
                   "integration_uuid" => uuid
                 })
      end
    end

    test "refuses binding to a personal or unknown mailbox", ctx do
      {:ok, personal} = Mailboxes.ensure_user_mailbox(ctx.alice)

      for uuid <- [personal.uuid, Ecto.UUID.generate()] do
        assert {:error, :mailbox_not_found} =
                 Identities.create_shared(scope_for(ctx.admin, @manage), %{
                   "label" => "Desk",
                   "integration_uuid" => ctx.system_smtp,
                   "mailbox_uuid" => uuid
                 })
      end
    end

    test "a blank label is a changeset error", ctx do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Identities.create_shared(scope_for(ctx.admin, @manage), %{
                 "label" => "  ",
                 "integration_uuid" => ctx.system_smtp
               })

      assert %{label: [_ | _]} = errors_on(changeset)
    end

    test "a from_name that would break the header is refused", ctx do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Identities.create_shared(scope_for(ctx.admin, @manage), %{
                 "label" => "Desk",
                 "from_name" => "Desk\r\nBcc: victim@example.com",
                 "integration_uuid" => ctx.system_smtp
               })

      assert %{from_name: [_ | _]} = errors_on(changeset)
    end
  end

  describe "create_personal/2" do
    test "binds the user's own mail integration to them", ctx do
      own = mail_integration_fixture({:user, ctx.alice.uuid}, username: "alice@own.test")

      assert {:ok, identity} =
               Identities.create_personal(scope_for(ctx.alice), %{
                 "label" => "My mail",
                 "integration_uuid" => own,
                 "owner_uuid" => ctx.bob.uuid,
                 "mailbox_uuid" => ctx.desk.uuid
               })

      assert identity.kind == "personal"
      assert identity.owner_uuid == ctx.alice.uuid
      assert identity.mailbox_uuid == nil
    end

    test "refuses another user's personal integration", ctx do
      bobs = mail_integration_fixture({:user, ctx.bob.uuid})

      assert {:error, {:integration_unusable, :owner_mismatch}} =
               Identities.create_personal(scope_for(ctx.alice), %{
                 "label" => "Bob's",
                 "integration_uuid" => bobs
               })
    end

    test "refuses a system integration", ctx do
      assert {:error, {:integration_unusable, :owner_mismatch}} =
               Identities.create_personal(scope_for(ctx.alice), %{
                 "label" => "System",
                 "integration_uuid" => ctx.system_smtp
               })
    end

    test "needs the inbox permission", ctx do
      own = mail_integration_fixture({:user, ctx.alice.uuid})

      assert {:error, :forbidden} =
               Identities.create_personal(scope_for(ctx.alice, []), %{
                 "label" => "Mine",
                 "integration_uuid" => own
               })
    end
  end

  describe "update_identity/3 and delete_identity/2" do
    test "a shared identity needs inbox.manage_shared", ctx do
      identity = shared!(ctx, label: "Desk", integration_uuid: ctx.system_smtp)

      assert {:error, :forbidden} =
               Identities.update_identity(scope_for(ctx.alice, @external), identity, %{
                 "label" => "Hijacked"
               })

      assert {:error, :forbidden} =
               Identities.delete_identity(scope_for(ctx.alice, @external), identity)

      assert {:ok, updated} =
               Identities.update_identity(scope_for(ctx.admin, @manage), identity, %{
                 "label" => "Front desk",
                 "from_name" => "Front"
               })

      assert updated.label == "Front desk"
      assert updated.from_name == "Front"
      assert :ok = Identities.delete_identity(scope_for(ctx.admin, @manage), identity)
      assert Repo.get(Identity, identity.uuid) == nil
    end

    test "a personal identity is its owner's alone", ctx do
      own = mail_integration_fixture({:user, ctx.alice.uuid})

      {:ok, identity} =
        Identities.create_personal(scope_for(ctx.alice), %{
          "label" => "Mine",
          "integration_uuid" => own
        })

      assert {:error, :forbidden} =
               Identities.update_identity(scope_for(ctx.bob, @manage), identity, %{
                 "label" => "Bob's now"
               })

      assert {:error, :forbidden} =
               Identities.delete_identity(scope_for(ctx.bob, @manage), identity)

      assert :ok = Identities.delete_identity(scope_for(ctx.alice), identity)
    end

    test "a hand-built struct grants nothing: the stored row decides", ctx do
      own = mail_integration_fixture({:user, ctx.alice.uuid})

      {:ok, identity} =
        Identities.create_personal(scope_for(ctx.alice), %{
          "label" => "Mine",
          "integration_uuid" => own
        })

      forged = %{identity | owner_uuid: ctx.bob.uuid}

      assert {:error, :forbidden} =
               Identities.update_identity(scope_for(ctx.bob), forged, %{"label" => "Bob's"})

      assert {:error, :forbidden} = Identities.delete_identity(scope_for(ctx.bob), forged)
    end

    test "switching to another integration checks it again", ctx do
      identity = shared!(ctx, label: "Desk", integration_uuid: ctx.system_smtp)
      personal = mail_integration_fixture({:user, ctx.alice.uuid})
      other_system = mail_integration_fixture(:system, username: "other@company.test")

      assert {:error, {:integration_unusable, :owner_mismatch}} =
               Identities.update_identity(scope_for(ctx.admin, @manage), identity, %{
                 "integration_uuid" => personal
               })

      assert {:ok, %Identity{integration_uuid: ^other_system}} =
               Identities.update_identity(scope_for(ctx.admin, @manage), identity, %{
                 "integration_uuid" => other_system
               })
    end
  end

  describe "list_usable/1" do
    setup ctx do
      bound =
        shared!(ctx,
          label: "Desk",
          integration_uuid: ctx.system_smtp,
          mailbox_uuid: ctx.desk.uuid
        )

      common = shared!(ctx, label: "Common", integration_uuid: ctx.system_smtp)
      own = mail_integration_fixture({:user, ctx.alice.uuid}, username: "alice@own.test")

      {:ok, personal} =
        Identities.create_personal(scope_for(ctx.alice), %{
          "label" => "Alice own",
          "integration_uuid" => own
        })

      %{bound: bound, common: common, personal: personal, own_integration: own}
    end

    defp usable(scope), do: scope |> Identities.list_usable() |> Enum.map(& &1.identity_uuid)

    test "a mailbox-bound identity needs write on that mailbox", ctx do
      grant_fixture(ctx.desk, ctx.bob, "read")
      refute ctx.bound.uuid in usable(scope_for(ctx.bob))

      grant_fixture(ctx.desk, ctx.bob, "write")
      assert ctx.bound.uuid in usable(scope_for(ctx.bob))
    end

    test "the common sender needs inbox.send_external", ctx do
      refute ctx.common.uuid in usable(scope_for(ctx.bob))
      assert ctx.common.uuid in usable(scope_for(ctx.bob, @external))
    end

    test "a personal identity is listed for its owner only", ctx do
      assert ctx.personal.uuid in usable(scope_for(ctx.alice))
      refute ctx.personal.uuid in usable(scope_for(ctx.bob, @manage ++ @external))
    end

    test "nothing without the inbox permission", ctx do
      assert usable(scope_for(ctx.alice, [])) == []
    end

    test "an archived mailbox's identity is not offered", ctx do
      grant_fixture(ctx.desk, ctx.bob, "write")
      {:ok, _} = Mailboxes.archive_mailbox(scope_for(ctx.admin), ctx.desk)

      refute ctx.bound.uuid in usable(scope_for(ctx.bob))
    end

    test "a broken identity is left out and marked broken", ctx do
      :ok =
        Integrations.remove_connection(ctx.own_integration, nil, owner: {:user, ctx.alice.uuid})

      refute ctx.personal.uuid in usable(scope_for(ctx.alice))
      assert Repo.get(Identity, ctx.personal.uuid).status == "broken"
    end

    test "each entry carries what a sender needs", ctx do
      grant_fixture(ctx.desk, ctx.bob, "write")

      entry =
        ctx.bob
        |> scope_for()
        |> Identities.list_usable()
        |> Enum.find(&(&1.identity_uuid == ctx.bound.uuid))

      assert entry.label == "Desk"
      assert entry.kind == "shared"
      assert entry.mailbox_uuid == ctx.desk.uuid
      assert entry.integration_uuid == ctx.system_smtp
      assert entry.from_address == "desk@company.test"
    end
  end

  describe "resolve/2 and resolve/3" do
    test "a bound identity sends as its from_name, else the mailbox name", ctx do
      grant_fixture(ctx.desk, ctx.bob, "write")

      named =
        shared!(ctx,
          label: "Desk",
          from_name: "Company Desk",
          integration_uuid: ctx.system_smtp,
          mailbox_uuid: ctx.desk.uuid
        )

      plain =
        shared!(ctx,
          label: "Desk 2",
          integration_uuid: ctx.system_smtp,
          mailbox_uuid: ctx.desk.uuid
        )

      assert {:ok, %{from_name: "Company Desk", from_address: "desk@company.test"} = resolved} =
               Identities.resolve(scope_for(ctx.bob), named.uuid)

      assert resolved.integration_uuid == ctx.system_smtp
      assert resolved.kind == "shared"
      assert {:ok, %{from_name: "Desk"}} = Identities.resolve(scope_for(ctx.bob), plain.uuid)
    end

    test "the common sender is \"<user> | <from_name>\"", ctx do
      common =
        shared!(ctx, label: "Common", from_name: "Company", integration_uuid: ctx.system_smtp)

      bare = shared!(ctx, label: "Bare", integration_uuid: ctx.system_smtp)

      assert {:ok, %{from_name: "Alice Smith | Company"}} =
               Identities.resolve(scope_for(ctx.alice, @external), common.uuid)

      assert {:ok, %{from_name: "Alice Smith"}} =
               Identities.resolve(scope_for(ctx.alice, @external), bare.uuid)
    end

    test "a personal identity sends as its from_name, else the owner's name", ctx do
      own = mail_integration_fixture({:user, ctx.alice.uuid}, username: "alice@own.test")

      {:ok, identity} =
        Identities.create_personal(scope_for(ctx.alice), %{
          "label" => "Mine",
          "integration_uuid" => own
        })

      assert {:ok, %{from_name: "Alice Smith", from_address: "alice@own.test"}} =
               Identities.resolve(scope_for(ctx.alice), identity.uuid)
    end

    test "refuses identities the scope may not use", ctx do
      common = shared!(ctx, label: "Common", integration_uuid: ctx.system_smtp)

      bound =
        shared!(ctx,
          label: "Desk",
          integration_uuid: ctx.system_smtp,
          mailbox_uuid: ctx.desk.uuid
        )

      own = mail_integration_fixture({:user, ctx.alice.uuid})

      {:ok, personal} =
        Identities.create_personal(scope_for(ctx.alice), %{
          "label" => "Mine",
          "integration_uuid" => own
        })

      grant_fixture(ctx.desk, ctx.bob, "read")
      bob = scope_for(ctx.bob, @manage)

      assert {:error, :forbidden} = Identities.resolve(bob, common.uuid)
      assert {:error, :forbidden} = Identities.resolve(bob, bound.uuid)
      assert {:error, :forbidden} = Identities.resolve(bob, personal.uuid)
      assert {:error, :forbidden} = Identities.resolve(scope_for(ctx.alice, []), personal.uuid)
    end

    test "an unknown or malformed uuid is not found", ctx do
      for uuid <- [Ecto.UUID.generate(), "nope", nil] do
        assert {:error, :not_found} = Identities.resolve(scope_for(ctx.admin, @manage), uuid)
      end
    end

    test "an identity whose integration is gone is broken until it works again", ctx do
      own = mail_integration_fixture({:user, ctx.alice.uuid}, username: "alice@own.test")
      scope = scope_for(ctx.alice)

      {:ok, identity} =
        Identities.create_personal(scope, %{"label" => "Mine", "integration_uuid" => own})

      Integrations.disconnect(own, nil, owner: {:user, ctx.alice.uuid})

      assert {:error, :broken} = Identities.resolve(scope, identity.uuid)
      assert Repo.get(Identity, identity.uuid).status == "broken"

      {:ok, _} =
        Integrations.save_setup(
          own,
          %{"host" => "smtp.invalid", "port" => "587", "username" => "alice@own.test"},
          nil,
          owner: {:user, ctx.alice.uuid}
        )

      assert {:ok, _} = Identities.resolve(scope, identity.uuid)
      assert Repo.get(Identity, identity.uuid).status == "active"
    end

    test "an identity pointed at someone else's integration is broken", ctx do
      identity = shared!(ctx, label: "Common", integration_uuid: ctx.system_smtp)
      personal = mail_integration_fixture({:user, ctx.alice.uuid})

      Repo.update_all(from(i in Identity, where: i.uuid == ^identity.uuid),
        set: [integration_uuid: Ecto.UUID.dump!(personal)]
      )

      assert {:error, :broken} =
               Identities.resolve(scope_for(ctx.alice, @external), identity.uuid)

      assert {:error, :owner_mismatch} = Identities.check(Repo.get(Identity, identity.uuid))
    end

    test "resolve/3 also checks the identity belongs to the sending mailbox", ctx do
      other = shared_mailbox_fixture(ctx.admin, %{name: "Other"})
      grant_fixture(ctx.desk, ctx.alice, "write")
      grant_fixture(other, ctx.alice, "write")
      {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(ctx.alice)

      bound =
        shared!(ctx,
          label: "Desk",
          integration_uuid: ctx.system_smtp,
          mailbox_uuid: ctx.desk.uuid
        )

      common = shared!(ctx, label: "Common", integration_uuid: ctx.system_smtp)
      own = mail_integration_fixture({:user, ctx.alice.uuid})

      {:ok, personal} =
        Identities.create_personal(scope_for(ctx.alice), %{
          "label" => "Mine",
          "integration_uuid" => own
        })

      scope = scope_for(ctx.alice, @external)

      assert {:ok, _} = Identities.resolve(scope, bound.uuid, ctx.desk)
      assert {:error, :identity_not_for_mailbox} = Identities.resolve(scope, bound.uuid, other)
      assert {:error, :identity_not_for_mailbox} = Identities.resolve(scope, bound.uuid, alice_mb)

      assert {:ok, _} = Identities.resolve(scope, common.uuid, alice_mb)

      assert {:error, :identity_not_for_mailbox} =
               Identities.resolve(scope, common.uuid, ctx.desk)

      assert {:ok, _} = Identities.resolve(scope, personal.uuid, alice_mb)

      assert {:error, :identity_not_for_mailbox} =
               Identities.resolve(scope, personal.uuid, ctx.desk)
    end
  end

  describe "reply_to_options/2" do
    test "the user's email and the addresses of shared mailboxes they can write to", ctx do
      readonly =
        shared_mailbox_fixture(ctx.admin, %{name: "Sales", address: "sales@company.test"})

      no_address = shared_mailbox_fixture(ctx.admin, %{name: "Notes"})
      grant_fixture(ctx.desk, ctx.alice, "write")
      grant_fixture(readonly, ctx.alice, "read")
      grant_fixture(no_address, ctx.alice, "admin")
      {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(ctx.alice)

      options = Identities.reply_to_options(scope_for(ctx.alice), alice_mb)
      addresses = Enum.map(options, & &1.address)

      assert Enum.sort(addresses) == Enum.sort([ctx.alice.email, "desk@company.test"])
      assert [%{address: default}] = Enum.filter(options, & &1.default)
      assert default == ctx.alice.email
    end

    test "a shared mailbox defaults to its own address", ctx do
      grant_fixture(ctx.desk, ctx.alice, "write")

      options = Identities.reply_to_options(scope_for(ctx.alice), ctx.desk)

      assert Identities.default_reply_to(options) == "desk@company.test"
    end

    test "a shared mailbox without an address has no default", ctx do
      notes = shared_mailbox_fixture(ctx.admin, %{name: "Notes"})
      grant_fixture(notes, ctx.alice, "write")

      options = Identities.reply_to_options(scope_for(ctx.alice), notes)

      assert Enum.map(options, & &1.address) == [ctx.alice.email]
      assert Identities.default_reply_to(options) == nil
    end

    test "nothing without inbox or without write on the mailbox", ctx do
      {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(ctx.alice)
      grant_fixture(ctx.desk, ctx.bob, "read")

      assert Identities.reply_to_options(scope_for(ctx.alice, []), alice_mb) == []
      assert Identities.reply_to_options(scope_for(ctx.bob), ctx.desk) == []
      assert Identities.reply_to_options(scope_for(ctx.bob), alice_mb) == []
    end

    test "the personal default is the one saved in the settings while it is allowed", ctx do
      grant_fixture(ctx.desk, ctx.alice, "write")
      {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(ctx.alice)
      scope = scope_for(ctx.alice)

      assert {:ok, _} = Identities.set_default_reply_to(scope, "DESK@company.test")

      assert scope |> Identities.reply_to_options(alice_mb) |> Identities.default_reply_to() ==
               "desk@company.test"

      # Losing the grant drops the address from the options, and the default
      # falls back to the user's email rather than keeping a forbidden one.
      Repo.delete_all(PhoenixKitInbox.Schemas.MailboxGrant)

      assert scope |> Identities.reply_to_options(alice_mb) |> Identities.default_reply_to() ==
               ctx.alice.email
    end

    test "a default outside the options is refused", ctx do
      assert {:error, :reply_to_not_allowed} =
               Identities.set_default_reply_to(scope_for(ctx.alice), "desk@company.test")

      assert {:error, :reply_to_not_allowed} =
               Identities.set_default_reply_to(scope_for(ctx.alice), "anyone@elsewhere.test")
    end
  end
end
