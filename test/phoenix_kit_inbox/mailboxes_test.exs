defmodule PhoenixKitInbox.MailboxesTest do
  use PhoenixKitInbox.DataCase, async: true

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Members
  alias PhoenixKitInbox.Schemas.Mailbox

  describe "ensure_user_mailbox/1" do
    test "creates a personal mailbox on first call and reuses it afterwards" do
      user = user_fixture()

      assert {:ok, %Mailbox{} = first} = Mailboxes.ensure_user_mailbox(user)
      assert first.kind == "user"
      assert first.owner_uuid == user.uuid
      assert first.address == user.email

      assert {:ok, second} = Mailboxes.ensure_user_mailbox(user)
      assert second.uuid == first.uuid
    end

    test "the slug is derived from the uuid, not the email — emails change" do
      user = user_fixture()
      {:ok, mailbox} = Mailboxes.ensure_user_mailbox(user)

      assert mailbox.slug == "u-" <> String.replace(user.uuid, "-", "")
    end

    test "rejects anything that isn't a user" do
      assert {:error, :invalid_user} = Mailboxes.ensure_user_mailbox(%{})
    end

    test "the personal-mailbox unique index rejects a second one for the same user" do
      user = user_fixture()
      {:ok, _} = Mailboxes.ensure_user_mailbox(user)

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%Mailbox{
          name: "Sneaky second",
          slug: "sneaky-#{System.unique_integer([:positive])}",
          kind: "user",
          owner_uuid: user.uuid
        })
      end
    end
  end

  describe "shared mailboxes" do
    setup do
      enable_inbox!()
      owner = user_fixture()

      %{owner: owner, manager: scope_for(owner, ["inbox", "inbox.manage_shared"])}
    end

    test "create_shared_mailbox/2 derives a slug from the name", %{owner: owner, manager: manager} do
      assert {:ok, mailbox} =
               Mailboxes.create_shared_mailbox(manager, %{
                 name: "Customer Support",
                 address: "support@example.com"
               })

      assert mailbox.kind == "shared"
      assert mailbox.slug == "customer-support"
      assert mailbox.owner_uuid == owner.uuid
    end

    test "slugs are globally unique", %{manager: manager} do
      {:ok, _} = Mailboxes.create_shared_mailbox(manager, %{name: "Sales"})

      assert {:error, changeset} = Mailboxes.create_shared_mailbox(manager, %{name: "Sales"})
      assert %{slug: _} = errors_on(changeset)
    end

    test "a user may own many shared mailboxes", %{manager: manager} do
      assert {:ok, _} = Mailboxes.create_shared_mailbox(manager, %{name: "One"})
      assert {:ok, _} = Mailboxes.create_shared_mailbox(manager, %{name: "Two"})
    end

    test "creating one needs inbox.manage_shared, not just inbox", %{owner: owner} do
      assert {:error, :forbidden} =
               Mailboxes.create_shared_mailbox(scope_for(owner), %{name: "Rogue"})

      assert Mailboxes.list_shared_mailboxes() == []
    end

    test "an anonymous scope can't create one" do
      assert {:error, :forbidden} =
               Mailboxes.create_shared_mailbox(Scope.for_user(nil), %{
                 name: "Nobody's"
               })
    end

    test "there is no unchecked creation path taking a bare owner uuid", %{owner: owner} do
      assert_raise FunctionClauseError, fn ->
        Mailboxes.create_shared_mailbox(owner.uuid, %{name: "Backdoor"})
      end
    end

    test "an address is unique regardless of case", %{manager: manager} do
      {:ok, _} =
        Mailboxes.create_shared_mailbox(manager, %{name: "A", address: "desk@example.com"})

      assert {:error, changeset} =
               Mailboxes.create_shared_mailbox(manager, %{name: "B", address: "Desk@Example.COM"})

      assert %{address: [_]} = errors_on(changeset)
    end

    test "an address can't be a user's login email", %{manager: manager} do
      user_fixture(%{email: "taken@example.com"})

      assert {:error, changeset} =
               Mailboxes.create_shared_mailbox(manager, %{
                 name: "Taken",
                 address: "TAKEN@example.com"
               })

      assert %{address: [_]} = errors_on(changeset)
    end

    test "update_mailbox/3 lets a mailbox admin rename it", %{owner: owner, manager: manager} do
      {:ok, shared} = Mailboxes.create_shared_mailbox(manager, %{name: "Old name"})

      assert {:ok, renamed} =
               Mailboxes.update_mailbox(scope_for(owner), shared, %{name: "New name"})

      assert renamed.name == "New name"
    end

    test "update_mailbox/3 refuses an address change without inbox.manage_shared", ctx do
      {:ok, shared} = Mailboxes.create_shared_mailbox(ctx.manager, %{name: "Front"})

      assert {:error, :forbidden} =
               Mailboxes.update_mailbox(scope_for(ctx.owner), shared, %{
                 address: "front@example.com"
               })

      assert {:ok, updated} =
               Mailboxes.update_mailbox(ctx.manager, shared, %{address: "front@example.com"})

      assert updated.address == "front@example.com"
    end

    test "update_mailbox/3 refuses someone without admin on the mailbox", %{manager: manager} do
      {:ok, shared} = Mailboxes.create_shared_mailbox(manager, %{name: "Locked"})
      stranger = scope_for(user_fixture(), ["inbox", "inbox.manage_shared"])

      assert {:error, :mailbox_access_denied} =
               Mailboxes.update_mailbox(stranger, shared, %{name: "Mine now"})
    end

    test "update_mailbox/3 can't move ownership or change the kind", ctx do
      {:ok, shared} = Mailboxes.create_shared_mailbox(ctx.manager, %{name: "Kept"})
      other = user_fixture()

      assert {:ok, updated} =
               Mailboxes.update_mailbox(ctx.manager, shared, %{
                 owner_uuid: other.uuid,
                 kind: "user"
               })

      assert updated.owner_uuid == ctx.owner.uuid
      assert updated.kind == "shared"
    end

    test "personal mailboxes can't be archived — mail must have somewhere to land" do
      user = user_fixture()
      {:ok, personal} = Mailboxes.ensure_user_mailbox(user)

      assert {:error, :cannot_archive_personal_mailbox} =
               Mailboxes.archive_mailbox(scope_for(user), personal)
    end

    test "archiving a shared mailbox removes it from the accessible list", %{owner: owner} do
      shared = shared_mailbox_fixture(owner, %{name: "Temp"})

      assert shared.uuid in mailbox_uuids(owner)
      assert {:ok, _} = Mailboxes.archive_mailbox(scope_for(owner), shared)
      refute shared.uuid in mailbox_uuids(owner)
    end
  end

  describe "access control" do
    setup do
      enable_inbox!()
      owner = user_fixture()
      other = user_fixture()
      shared = shared_mailbox_fixture(owner, %{name: "Support Desk"})

      %{owner: owner, other: other, shared: shared, owner_scope: scope_for(owner)}
    end

    test "the owner holds admin without any grant row", %{owner: owner, shared: shared} do
      assert Mailboxes.access_level(shared, owner.uuid) == "admin"
      assert Mailboxes.list_grants(shared.uuid) == []
    end

    test "a stranger holds nothing", %{other: other, shared: shared} do
      assert Mailboxes.access_level(shared, other.uuid) == nil
      assert {:error, :mailbox_access_denied} = Mailboxes.authorize(shared, other.uuid, "read")
    end

    test "granting read allows read but not write", ctx do
      {:ok, grant} = Mailboxes.grant_access(ctx.owner_scope, ctx.shared, ctx.other.uuid, "read")

      assert grant.granted_by_uuid == ctx.owner.uuid
      assert :ok = Mailboxes.authorize(ctx.shared, ctx.other.uuid, "read")

      assert {:error, :mailbox_access_denied} =
               Mailboxes.authorize(ctx.shared, ctx.other.uuid, "write")
    end

    test "admin covers every weaker level", %{other: other, shared: shared} do
      grant_fixture(shared, other, "admin")

      assert :ok = Mailboxes.authorize(shared, other.uuid, "read")
      assert :ok = Mailboxes.authorize(shared, other.uuid, "write")
      assert :ok = Mailboxes.authorize(shared, other.uuid, "admin")
    end

    test "re-granting updates the level instead of duplicating the row", ctx do
      {:ok, _} = Mailboxes.grant_access(ctx.owner_scope, ctx.shared, ctx.other.uuid, "read")
      {:ok, _} = Mailboxes.grant_access(ctx.owner_scope, ctx.shared, ctx.other.uuid, "write")

      assert length(Mailboxes.list_grants(ctx.shared.uuid)) == 1
      assert Mailboxes.access_level(ctx.shared, ctx.other.uuid) == "write"
    end

    test "revoking is idempotent", ctx do
      grant_fixture(ctx.shared, ctx.other, "read")

      assert :ok = Mailboxes.revoke_access(ctx.owner_scope, ctx.shared, ctx.other.uuid)
      assert :ok = Mailboxes.revoke_access(ctx.owner_scope, ctx.shared, ctx.other.uuid)
      assert Mailboxes.access_level(ctx.shared, ctx.other.uuid) == nil
    end

    test "a granted mailbox shows up in the sidebar list", %{other: other, shared: shared} do
      {:ok, _} = Mailboxes.ensure_user_mailbox(other)
      grant_fixture(shared, other, "read")

      assert shared.uuid in mailbox_uuids(other)
    end

    test "personal mailboxes sort before shared ones", %{owner: owner} do
      {:ok, personal} = Mailboxes.ensure_user_mailbox(owner)

      assert [first | _] = Mailboxes.list_accessible_mailboxes(owner.uuid)
      assert first.uuid == personal.uuid
    end
  end

  describe "mailbox administration refuses a forged caller" do
    setup do
      enable_inbox!()
      owner = user_fixture()
      shared = shared_mailbox_fixture(owner, %{name: "Guarded"})
      writer = user_fixture()
      grant_fixture(shared, writer, "write")
      target = user_fixture()

      %{
        owner: owner,
        shared: shared,
        target: target,
        stranger: scope_for(user_fixture()),
        writer: scope_for(writer),
        no_inbox: scope_for(owner, [])
      }
    end

    test "grant_access/4", ctx do
      for {scope, reason} <- [
            {ctx.stranger, :mailbox_access_denied},
            {ctx.writer, :mailbox_access_denied},
            {ctx.no_inbox, :forbidden},
            {Scope.for_user(nil), :forbidden}
          ] do
        assert {:error, ^reason} =
                 Mailboxes.grant_access(scope, ctx.shared, ctx.target.uuid, "admin")
      end

      assert Mailboxes.access_level(ctx.shared, ctx.target.uuid) == nil
    end

    test "grant_access/4 refuses grants on a personal mailbox", %{owner: owner, target: target} do
      {:ok, personal} = Mailboxes.ensure_user_mailbox(owner)

      assert {:error, :cannot_grant_personal_mailbox} =
               Mailboxes.grant_access(scope_for(owner), personal, target.uuid, "read")
    end

    test "grant_access/4 can't be talked into trusting a hand-built struct", ctx do
      # A struct claiming the stranger owns it: the stored row decides.
      forged = %{ctx.shared | owner_uuid: ctx.stranger.user.uuid}

      assert {:error, :mailbox_access_denied} =
               Mailboxes.grant_access(ctx.stranger, forged, ctx.target.uuid, "admin")
    end

    test "revoke_access/3", ctx do
      grant_fixture(ctx.shared, ctx.target, "read")

      for scope <- [ctx.stranger, ctx.writer, ctx.no_inbox] do
        assert {:error, _} = Mailboxes.revoke_access(scope, ctx.shared, ctx.target.uuid)
      end

      assert Mailboxes.access_level(ctx.shared, ctx.target.uuid) == "read"
    end

    test "archive_mailbox/2 and restore_mailbox/2", ctx do
      for scope <- [ctx.stranger, ctx.writer, ctx.no_inbox] do
        assert {:error, _} = Mailboxes.archive_mailbox(scope, ctx.shared)
      end

      assert {:ok, %{status: "active"}} = Mailboxes.fetch_mailbox(ctx.shared.uuid)

      {:ok, archived} = Mailboxes.archive_mailbox(scope_for(ctx.owner), ctx.shared)

      for scope <- [ctx.stranger, ctx.writer, ctx.no_inbox] do
        assert {:error, _} = Mailboxes.restore_mailbox(scope, archived)
      end

      assert {:ok, %{status: "archived"}} = Mailboxes.fetch_mailbox(ctx.shared.uuid)

      assert {:ok, %{status: "active"}} =
               Mailboxes.restore_mailbox(scope_for(ctx.owner), archived)
    end

    test "update_mailbox/3 needs the inbox permission, not only admin", ctx do
      assert {:error, :forbidden} =
               Mailboxes.update_mailbox(ctx.no_inbox, ctx.shared, %{name: "x"})
    end
  end

  describe "recipient resolution" do
    test "matches on address or slug, case-insensitively" do
      owner = user_fixture()

      shared =
        shared_mailbox_fixture(owner, %{
          name: "Billing",
          address: "billing@example.com"
        })

      assert {:ok, %{uuid: uuid}} = Mailboxes.fetch_mailbox_by_recipient("billing")
      assert uuid == shared.uuid

      assert {:ok, %{uuid: ^uuid}} = Mailboxes.fetch_mailbox_by_recipient("BILLING@example.com")
      assert {:ok, %{uuid: ^uuid}} = Mailboxes.fetch_mailbox_by_recipient("  billing  ")
    end

    test "an unknown handle is an error, not nil" do
      assert {:error, :recipient_not_found} = Mailboxes.fetch_mailbox_by_recipient("nobody-here")
    end

    test "archived mailboxes stop resolving" do
      owner = user_fixture()
      shared = shared_mailbox_fixture(owner, %{name: "Old Desk"})
      shared |> Ecto.Changeset.change(status: "archived") |> Repo.update!()

      assert {:error, :recipient_not_found} = Mailboxes.fetch_mailbox_by_recipient("old-desk")
    end

    test "a shared mailbox resolves by its display name, not only its slug" do
      owner = user_fixture()
      shared = shared_mailbox_fixture(owner, %{name: "Customer Support"})

      assert {:ok, %{uuid: uuid}} = Mailboxes.fetch_mailbox_by_recipient("Customer Support")
      assert uuid == shared.uuid
      assert {:ok, %{uuid: ^uuid}} = Mailboxes.fetch_mailbox_by_recipient("customer support")
    end

    test "a username resolves — the case that reported 'no mailbox matches'" do
      user = user_fixture(%{username: "fotkin", email: "fotkin@example.com"})
      {:ok, mailbox} = Mailboxes.ensure_user_mailbox(user)

      assert {:ok, %{uuid: uuid}} = Mailboxes.fetch_mailbox_by_recipient("fotkin")
      assert uuid == mailbox.uuid
    end

    test "a username resolves case-insensitively and ignores surrounding space" do
      user = user_fixture(%{username: "fotkin", email: "fotkin@example.com"})
      {:ok, mailbox} = Mailboxes.ensure_user_mailbox(user)

      for typed <- ["FOTKIN", "Fotkin", "  fotkin  "] do
        assert {:ok, %{uuid: uuid}} = Mailboxes.fetch_mailbox_by_recipient(typed),
               "#{inspect(typed)} did not resolve"

        assert uuid == mailbox.uuid
      end
    end

    test "a user who has never opened Inbox is still addressable" do
      # The mailbox is created lazily on first visit, so before this fix a
      # colleague who had not clicked the tab was unreachable by ANY spelling.
      user = user_fixture(%{username: "newcomer", email: "newcomer@example.com"})

      assert Mailboxes.list_accessible_mailboxes(user.uuid) == []

      assert {:ok, mailbox} = Mailboxes.fetch_mailbox_by_recipient("newcomer")
      assert mailbox.owner_uuid == user.uuid
      assert mailbox.kind == "user"
    end

    test "resolving the same absent user twice returns one mailbox, not two" do
      user = user_fixture(%{username: "newcomer2", email: "newcomer2@example.com"})

      assert {:ok, first} = Mailboxes.fetch_mailbox_by_recipient("newcomer2")
      assert {:ok, second} = Mailboxes.fetch_mailbox_by_recipient("newcomer2@example.com")

      assert first.uuid == second.uuid
    end

    test "an email resolves for a user with no mailbox yet" do
      user = user_fixture(%{username: "byemail", email: "byemail@example.com"})

      assert {:ok, mailbox} = Mailboxes.fetch_mailbox_by_recipient("ByEmail@example.com")
      assert mailbox.owner_uuid == user.uuid
    end

    test "an inactive user is not addressable" do
      user_fixture(%{username: "retired", email: "retired@example.com", is_active: false})

      assert {:error, :recipient_not_found} = Mailboxes.fetch_mailbox_by_recipient("retired")
    end

    test "a blank term never resolves" do
      for typed <- ["", "   ", "@", " @ "] do
        assert {:error, :recipient_not_found} = Mailboxes.fetch_mailbox_by_recipient(typed)
      end
    end

    test "@name is the username, the @ stripped, regardless of case" do
      user = user_fixture(%{username: "Mari", email: "mari@example.com"})

      for typed <- ["@mari", "@MARI", " @Mari "] do
        assert {:ok, mailbox} = Mailboxes.fetch_mailbox_by_recipient(typed),
               "#{inspect(typed)} did not resolve"

        assert mailbox.owner_uuid == user.uuid
      end
    end

    test "@name finds the user before a shared mailbox of the same name; a bare name the mailbox" do
      user = user_fixture(%{username: "sales", email: "sales.person@example.com"})
      shared = shared_mailbox_fixture(user_fixture(), %{name: "Sales"})

      assert {:ok, %{owner_uuid: owner}} = Mailboxes.fetch_mailbox_by_recipient("@sales")
      assert owner == user.uuid

      assert {:ok, %{uuid: uuid}} = Mailboxes.fetch_mailbox_by_recipient("sales")
      assert uuid == shared.uuid
    end

    test "@name falls back to a shared mailbox when no user has that username" do
      shared = shared_mailbox_fixture(user_fixture(), %{name: "Helpline"})

      assert {:ok, %{uuid: uuid}} = Mailboxes.fetch_mailbox_by_recipient("@helpline")
      assert uuid == shared.uuid
    end

    test "an email finds the user before a shared mailbox carrying the same address" do
      user = user_fixture(%{username: "kai", email: "kai@example.com"})
      # Only reachable with pre-V02 data: saving such an address is refused now.
      shared_mailbox_fixture(user_fixture(), %{name: "Kai desk", address: "kai@example.com"})

      assert {:ok, %{owner_uuid: owner}} = Mailboxes.fetch_mailbox_by_recipient("KAI@example.com")
      assert owner == user.uuid
    end

    test "a personal mailbox is not reached through its stale address snapshot" do
      user = user_fixture(%{username: "mover", email: "old@example.com"})
      {:ok, _} = Mailboxes.ensure_user_mailbox(user)

      user |> Ecto.Changeset.change(email: "new@example.com") |> Repo.update!()

      assert {:error, :recipient_not_found} =
               Mailboxes.fetch_mailbox_by_recipient("old@example.com")

      assert {:ok, %{owner_uuid: owner}} = Mailboxes.fetch_mailbox_by_recipient("new@example.com")
      assert owner == user.uuid
    end

    test "two shared mailboxes with the same name are ambiguous" do
      owner = user_fixture()
      shared_mailbox_fixture(owner, %{name: "Desk", slug: "desk-a"})
      shared_mailbox_fixture(owner, %{name: "Desk", slug: "desk-b"})

      assert {:error, :ambiguous_recipient} = Mailboxes.fetch_mailbox_by_recipient("desk")
      assert {:ok, %{slug: "desk-a"}} = Mailboxes.fetch_mailbox_by_recipient("desk-a")
    end
  end

  describe "recipient circle" do
    test "a user outside the circle is not addressable by username or email" do
      user_fixture(%{username: "customer", email: "customer@example.com", inbox_member: false})

      for typed <- ["@customer", "customer", "customer@example.com"] do
        assert {:error, :recipient_not_found} = Mailboxes.fetch_mailbox_by_recipient(typed),
               "#{inspect(typed)} resolved to a non-member"
      end
    end

    test "any held role carrying inbox makes a member, not only one role" do
      user = user_fixture(%{username: "multi", email: "multi@example.com", inbox_member: false})
      grant_role!(user, [])
      grant_role!(user, ["inbox"])

      assert Members.member?(user)
      assert {:ok, _} = Mailboxes.fetch_mailbox_by_recipient("@multi")
    end

    test "a role carrying the superadmin key makes a member" do
      user = user_fixture(%{username: "star", email: "star@example.com", inbox_member: false})
      grant_role!(user, ["*"])

      assert Members.member?(user)
    end

    test "the Owner is a member without any permission rows" do
      user = user_fixture(%{username: "boss", email: "boss@example.com", inbox_member: false})
      grant_role!(user, [], name: "Owner")

      assert Members.member?(user)
      assert {:ok, _} = Mailboxes.fetch_mailbox_by_recipient("@boss")
    end

    test "a role without inbox doesn't make a member" do
      user = user_fixture(%{username: "plain", email: "plain@example.com", inbox_member: false})
      grant_role!(user, ["users"])

      refute Members.member?(user)
    end

    test "suggestions leave non-members out" do
      me = user_fixture()
      user_fixture(%{username: "outsider", email: "outsider@example.com", inbox_member: false})

      handles = me.uuid |> Mailboxes.search_recipients("outsider") |> Enum.map(& &1.handle)

      assert handles == []
    end
  end

  describe "search_recipients/3 (compose suggestions)" do
    test "offers users who have no mailbox yet" do
      me = user_fixture()
      them = user_fixture(%{username: "suggestme", email: "suggestme@example.com"})

      handles = me.uuid |> Mailboxes.search_recipients() |> Enum.map(& &1.handle)

      assert "@suggestme" in handles
      assert Mailboxes.list_accessible_mailboxes(them.uuid) == []
    end

    test "every suggested handle actually resolves" do
      me = user_fixture()
      user_fixture(%{username: "resolvable", email: "resolvable@example.com"})
      _ = shared_mailbox_fixture(me, %{name: "Helpdesk"})

      for %{handle: handle} <- Mailboxes.search_recipients(me.uuid) do
        assert {:ok, _mailbox} = Mailboxes.fetch_mailbox_by_recipient(handle),
               "suggested handle #{inspect(handle)} does not resolve"
      end
    end

    test "does not suggest the sender to themselves" do
      me = user_fixture(%{username: "myself", email: "myself@example.com"})

      handles = me.uuid |> Mailboxes.search_recipients() |> Enum.map(& &1.handle)

      refute "@myself" in handles
    end

    test "filters on username, email and name" do
      me = user_fixture()

      user_fixture(%{
        username: "zzfindme",
        email: "zzfindme@example.com",
        first_name: "Zaphod",
        last_name: "Beeblebrox"
      })

      for term <- ["zzfindme", "zzfindme@exam", "Zaphod", "Beeblebrox"] do
        handles = me.uuid |> Mailboxes.search_recipients(term) |> Enum.map(& &1.handle)
        assert "@zzfindme" in handles, "term #{inspect(term)} did not surface the user"
      end
    end

    test "shared mailboxes are offered by slug and labelled as shared" do
      me = user_fixture()
      _ = shared_mailbox_fixture(me, %{name: "Night Desk"})

      suggestion =
        me.uuid
        |> Mailboxes.search_recipients("night")
        |> Enum.find(&(&1.handle == "night-desk"))

      assert suggestion
      assert suggestion.label =~ "shared mailbox"
    end

    test "a blank term lists candidates rather than nothing" do
      me = user_fixture()
      user_fixture(%{username: "listed", email: "listed@example.com"})

      assert me.uuid |> Mailboxes.search_recipients("") |> length() > 0
    end

    test "a user with a username is offered as @username, without the email" do
      me = user_fixture()

      user_fixture(%{
        username: "quiet",
        email: "quiet@example.com",
        first_name: "Q",
        last_name: "Uiet"
      })

      assert [suggestion] = Mailboxes.search_recipients(me.uuid, "quiet")
      assert suggestion.handle == "@quiet"
      refute suggestion.label =~ "quiet@example.com"
      assert suggestion.label =~ "Q Uiet"
    end

    test "a user without a username is offered by email" do
      me = user_fixture()
      user_fixture(%{username: nil, email: "nousername@example.com"})

      assert [suggestion] = Mailboxes.search_recipients(me.uuid, "nousername")
      assert suggestion.handle == "nousername@example.com"
      assert {:ok, _} = Mailboxes.fetch_mailbox_by_recipient(suggestion.handle)
    end

    test "respects the limit" do
      me = user_fixture()
      for _ <- 1..5, do: user_fixture()

      assert me.uuid |> Mailboxes.search_recipients("", limit: 2) |> length() <= 2
    end
  end

  describe "user_display_name/1" do
    test "prefers the full name, then username, then the email local part" do
      assert Mailboxes.user_display_name(%{first_name: "Ada", last_name: "Lovelace"}) ==
               "Ada Lovelace"

      assert Mailboxes.user_display_name(%{username: "ada", email: "ada@example.com"}) == "ada"
      assert Mailboxes.user_display_name(%{email: "ada@example.com"}) == "ada"
    end
  end

  defp mailbox_uuids(user) do
    user.uuid |> Mailboxes.list_accessible_mailboxes() |> Enum.map(& &1.uuid)
  end
end
