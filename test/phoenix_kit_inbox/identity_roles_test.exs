defmodule PhoenixKitInbox.IdentityRolesTest do
  @moduledoc """
  The roles a shared sender bound to no mailbox (the common sender) is open
  to: kept with `create_shared/2` and `update_identity/3`, listed by
  `list_shared/1`, and checked — on top of `inbox.send_external` — by
  `list_usable/1,2` and `resolve/2,3` against the scope's roles in effect.
  """

  use PhoenixKitInbox.DataCase, async: false

  alias PhoenixKit.Users.Role
  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Schemas.IdentityRole

  @manage ["inbox", "inbox.manage_shared"]
  @external ["inbox", "inbox.send_external"]

  setup do
    enable_inbox!()
    admin = user_fixture()
    alice = user_fixture(%{first_name: "Alice", last_name: "Smith"})
    desk = shared_mailbox_fixture(admin, %{name: "Desk"})
    system_smtp = mail_integration_fixture(:system, username: "noreply@company.test")

    sales = grant_role!(alice, ["inbox", "inbox.send_external"])
    super = grant_role!(user_fixture(), ["*"])
    reader = grant_role!(user_fixture(), ["inbox"])
    owner_role = Repo.get_by!(Role, name: "Owner")

    %{
      admin: admin,
      alice: alice,
      desk: desk,
      system_smtp: system_smtp,
      manager: scope_for(admin, @manage),
      sales: sales,
      super: super,
      reader: reader,
      owner_role: owner_role
    }
  end

  defp common!(ctx, attrs \\ %{}) do
    {:ok, identity} =
      Identities.create_shared(
        ctx.manager,
        Map.merge(%{"label" => "Common", "integration_uuid" => ctx.system_smtp}, attrs)
      )

    identity
  end

  defp role_uuids(identity) do
    Repo.all(
      from(r in IdentityRole, where: r.identity_uuid == ^identity.uuid, select: r.role_uuid)
    )
    |> Enum.sort()
  end

  defp usable(scope), do: scope |> Identities.list_usable() |> Enum.map(& &1.identity_uuid)

  describe "create_shared/2" do
    test "without \"role_uuids\" it opens to the roles that may send externally, not Owner",
         ctx do
      identity = common!(ctx)

      assert role_uuids(identity) == Enum.sort([ctx.sales.uuid, ctx.super.uuid])
    end

    test "with \"role_uuids\" exactly those, Owner and unknown ones dropped", ctx do
      identity =
        common!(ctx, %{
          "role_uuids" => [
            ctx.reader.uuid,
            ctx.owner_role.uuid,
            Ecto.UUID.generate(),
            "not-a-uuid",
            nil,
            ""
          ]
        })

      # A role without the right to send externally is kept: the right is
      # checked per user at send time.
      assert role_uuids(identity) == [ctx.reader.uuid]
    end

    test "a list sent as a map of index => uuid is read the same", ctx do
      identity = common!(ctx, %{"role_uuids" => %{"0" => ctx.sales.uuid, "1" => ctx.reader.uuid}})

      assert role_uuids(identity) == Enum.sort([ctx.sales.uuid, ctx.reader.uuid])
    end

    test "an empty list opens it to nobody", ctx do
      assert role_uuids(common!(ctx, %{"role_uuids" => []})) == []
    end

    test "a sender bound to a mailbox keeps no roles", ctx do
      identity =
        common!(ctx, %{"mailbox_uuid" => ctx.desk.uuid, "role_uuids" => [ctx.sales.uuid]})

      assert role_uuids(identity) == []
    end
  end

  describe "update_identity/3" do
    test "replaces the roles with the fields, for a holder of inbox.manage_shared", ctx do
      identity = common!(ctx, %{"role_uuids" => [ctx.sales.uuid]})

      assert {:ok, updated} =
               Identities.update_identity(ctx.manager, identity, %{
                 "label" => "Renamed",
                 "role_uuids" => [ctx.reader.uuid, ctx.owner_role.uuid]
               })

      assert updated.label == "Renamed"
      assert role_uuids(identity) == [ctx.reader.uuid]
    end

    test "without \"role_uuids\" the roles stay", ctx do
      identity = common!(ctx, %{"role_uuids" => [ctx.sales.uuid]})

      assert {:ok, _} = Identities.update_identity(ctx.manager, identity, %{"label" => "New"})
      assert role_uuids(identity) == [ctx.sales.uuid]
    end

    test "nothing changes when a field is refused", ctx do
      identity = common!(ctx, %{"role_uuids" => [ctx.sales.uuid]})

      assert {:error, %Ecto.Changeset{}} =
               Identities.update_identity(ctx.manager, identity, %{
                 "label" => "",
                 "role_uuids" => [ctx.reader.uuid]
               })

      assert role_uuids(identity) == [ctx.sales.uuid]
    end

    test "is refused without inbox.manage_shared", ctx do
      identity = common!(ctx, %{"role_uuids" => [ctx.sales.uuid]})

      assert {:error, :forbidden} =
               Identities.update_identity(
                 scope_for(ctx.alice, @external, [ctx.sales]),
                 identity,
                 %{
                   "role_uuids" => [ctx.reader.uuid]
                 }
               )

      assert role_uuids(identity) == [ctx.sales.uuid]
    end

    test "binding to a mailbox drops the roles; a bound one takes none", ctx do
      identity = common!(ctx, %{"role_uuids" => [ctx.sales.uuid]})

      assert {:ok, _} =
               Identities.update_identity(ctx.manager, identity, %{
                 "mailbox_uuid" => ctx.desk.uuid
               })

      assert role_uuids(identity) == []

      assert {:ok, _} =
               Identities.update_identity(ctx.manager, identity, %{
                 "role_uuids" => [ctx.sales.uuid]
               })

      assert role_uuids(identity) == []

      # Unbound again through the API: open to nobody until roles are chosen.
      assert {:ok, _} = Identities.update_identity(ctx.manager, identity, %{"mailbox_uuid" => ""})
      assert role_uuids(identity) == []
    end
  end

  describe "list_shared/1" do
    test "lists each sender's roles with their names", ctx do
      identity = common!(ctx, %{"role_uuids" => [ctx.sales.uuid, ctx.reader.uuid]})

      bound =
        common!(ctx, %{"label" => "Desk", "mailbox_uuid" => ctx.desk.uuid})

      listed = Map.new(Identities.list_shared(ctx.manager), &{&1.identity.uuid, &1.roles})

      assert Enum.sort(listed[identity.uuid]) ==
               Enum.sort([
                 %{uuid: ctx.sales.uuid, name: ctx.sales.name},
                 %{uuid: ctx.reader.uuid, name: ctx.reader.name}
               ])

      assert listed[bound.uuid] == []
    end
  end

  describe "role_choices/1" do
    test "every role but Owner, marked by whether it gives the right to send externally",
         ctx do
      choices = Map.new(Identities.role_choices(ctx.manager), &{&1.uuid, &1})

      refute Map.has_key?(choices, ctx.owner_role.uuid)
      assert %{name: name, sends_external: true} = choices[ctx.sales.uuid]
      assert name == ctx.sales.name
      assert choices[ctx.super.uuid].sends_external
      refute choices[ctx.reader.uuid].sends_external
    end

    test "a role holding send_external without inbox does not give it", ctx do
      half = grant_role!(user_fixture(), ["inbox.send_external"])

      refute Enum.find(Identities.role_choices(ctx.manager), &(&1.uuid == half.uuid)).sends_external
    end

    test "nothing without inbox.manage_shared", ctx do
      assert Identities.role_choices(scope_for(ctx.alice, @external)) == []
    end
  end

  describe "who may send as the common sender" do
    setup ctx do
      %{common: common!(ctx, %{"role_uuids" => [ctx.sales.uuid]})}
    end

    test "a role in effect that is on the list, with inbox.send_external", ctx do
      scope = scope_for(ctx.alice, @external, [ctx.sales])

      assert ctx.common.uuid in usable(scope)
      assert {:ok, _} = Identities.resolve(scope, ctx.common.uuid)
      {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(ctx.alice)
      assert {:ok, _} = Identities.resolve(scope, ctx.common.uuid, alice_mb)
    end

    test "a role off the list: not offered, refused", ctx do
      scope = scope_for(ctx.alice, @external, [ctx.reader])

      refute ctx.common.uuid in usable(scope)
      assert {:error, :forbidden} = Identities.resolve(scope, ctx.common.uuid)
      {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(ctx.alice)
      assert {:error, :forbidden} = Identities.resolve(scope, ctx.common.uuid, alice_mb)
    end

    test "a role on the list without inbox.send_external is not enough", ctx do
      scope = scope_for(ctx.alice, ["inbox"], [ctx.sales])

      refute ctx.common.uuid in usable(scope)
      assert {:error, :forbidden} = Identities.resolve(scope, ctx.common.uuid)
    end

    test "a ticked role that lacks the right counts when another role gives it", ctx do
      identity = common!(ctx, %{"role_uuids" => [ctx.reader.uuid]})
      scope = scope_for(ctx.alice, @external, [ctx.reader, ctx.sales])

      assert identity.uuid in usable(scope)
      assert {:ok, _} = Identities.resolve(scope, identity.uuid)
    end

    test "an empty list: nobody but Owner", ctx do
      identity = common!(ctx, %{"role_uuids" => []})

      refute identity.uuid in usable(scope_for(ctx.alice, @external, [ctx.sales]))

      assert {:error, :forbidden} =
               Identities.resolve(scope_for(ctx.alice, @external, [ctx.sales]), identity.uuid)

      owner = scope_for(ctx.admin, @external, ["Owner"])
      assert identity.uuid in usable(owner)
      assert {:ok, _} = Identities.resolve(owner, identity.uuid)
    end

    test "Owner acting as another role goes by that role", ctx do
      acting = scope_for(ctx.admin, @external, [ctx.reader], ["Owner", ctx.reader])

      refute ctx.common.uuid in usable(acting)
      assert {:error, :forbidden} = Identities.resolve(acting, ctx.common.uuid)
    end

    test "a user of two roles acting as the one off the list", ctx do
      # Alice holds sales (on the list) and reader; acting as reader, only
      # reader is in effect.
      grant_role!(ctx.alice, [], name: ctx.reader.name)
      acting = scope_for(ctx.alice, @external, [ctx.reader], [ctx.sales, ctx.reader])

      refute ctx.common.uuid in usable(acting)
      assert {:error, :forbidden} = Identities.resolve(acting, ctx.common.uuid)
    end

    test "a superadmin-key role goes by the list like any other", ctx do
      ticked = common!(ctx, %{"role_uuids" => [ctx.super.uuid]})
      scope = scope_for(ctx.alice, ["*"], [ctx.super])

      assert ticked.uuid in usable(scope)
      refute ctx.common.uuid in usable(scope)
    end

    test "a sender bound to a mailbox goes by the mailbox, as before", ctx do
      bound = common!(ctx, %{"label" => "Desk", "mailbox_uuid" => ctx.desk.uuid})
      grant_fixture(ctx.desk, ctx.alice, "write")

      assert bound.uuid in usable(scope_for(ctx.alice))
      assert {:ok, _} = Identities.resolve(scope_for(ctx.alice), bound.uuid, ctx.desk)
    end

    test "a role deleted from the site leaves the list", ctx do
      role = grant_role!(user_fixture(), ["inbox", "inbox.send_external"])
      identity = common!(ctx, %{"role_uuids" => [role.uuid, ctx.sales.uuid]})

      Repo.delete_all(
        from(a in PhoenixKit.Users.RoleAssignment, where: a.role_uuid == ^role.uuid)
      )

      Repo.delete!(role)

      assert role_uuids(identity) == [ctx.sales.uuid]
    end

    test "the nudge sends as it whatever its roles", ctx do
      identity = common!(ctx, %{"role_uuids" => []})

      assert {:ok, %{identity_uuid: uuid}} = Identities.resolve_system(identity.uuid)
      assert uuid == identity.uuid
    end
  end

  describe "list_usable/2" do
    test "only the senders that fit the sending mailbox", ctx do
      common = common!(ctx, %{"role_uuids" => [ctx.sales.uuid]})
      bound = common!(ctx, %{"label" => "Desk", "mailbox_uuid" => ctx.desk.uuid})
      grant_fixture(ctx.desk, ctx.alice, "write")
      {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(ctx.alice)
      scope = scope_for(ctx.alice, @external, [ctx.sales])

      assert Enum.map(Identities.list_usable(scope, alice_mb), & &1.identity_uuid) == [
               common.uuid
             ]

      assert Enum.map(Identities.list_usable(scope, ctx.desk), & &1.identity_uuid) == [bound.uuid]
    end
  end
end
