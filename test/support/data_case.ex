defmodule PhoenixKitInbox.DataCase do
  @moduledoc """
  Test case for tests requiring database access.

  Uses PhoenixKitInbox.Test.Repo with SQL Sandbox for isolation.
  Tests using this case are tagged `:integration` and will be
  automatically excluded when the database is unavailable.

  ## Usage

      defmodule MyModule.Integration.SomeTest do
        use PhoenixKitInbox.DataCase, async: true

        test "creates a record" do
          # Repo is available, transactions are isolated
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration

      alias PhoenixKitInbox.Test.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import PhoenixKitInbox.ActivityLogAssertions
      import PhoenixKitInbox.DataCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Role
  alias PhoenixKit.Users.RoleAssignment
  alias PhoenixKit.Users.RolePermission
  alias PhoenixKitInbox.Schemas.Mailbox
  alias PhoenixKitInbox.Schemas.MailboxGrant
  alias PhoenixKitInbox.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])

    on_exit(fn -> Sandbox.stop_owner(pid) end)

    :ok
  end

  @doc """
  Inserts a real `phoenix_kit_users` row.

  Inbox's tables carry foreign keys to `phoenix_kit_users`, so a fabricated
  uuid fails on insert — every mailbox needs an owner that actually exists.
  Inserted through the schema (rather than raw SQL) so the row matches whatever
  core's current columns are.

  The user is an Inbox member — addressable — through a role of their own
  holding the `"inbox"` permission. Pass `inbox_member: false` for a user
  outside the recipient circle (a customer account, say).
  """
  def user_fixture(attrs \\ %{}) do
    {member?, attrs} = Map.pop(attrs, :inbox_member, true)
    user = insert_user!(attrs)
    if member?, do: grant_role!(user, ["inbox"])
    user
  end

  @doc """
  Gives `user` a fresh role holding `permission_keys` (`[]` for none). With
  `name:` the role is looked up by name instead (e.g. `"Owner"`, seeded by
  core) and the keys are ignored.
  """
  def grant_role!(user, permission_keys, opts \\ []) do
    role =
      case Keyword.get(opts, :name) do
        nil ->
          role =
            TestRepo.insert!(%Role{
              name: "inbox-test-role-#{System.unique_integer([:positive])}"
            })

          for key <- permission_keys do
            TestRepo.insert!(%RolePermission{
              role_uuid: role.uuid,
              module_key: key
            })
          end

          role

        name ->
          TestRepo.get_by!(Role, name: name)
      end

    TestRepo.insert!(%RoleAssignment{
      user_uuid: user.uuid,
      role_uuid: role.uuid,
      assigned_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    role
  end

  defp insert_user!(attrs) do
    n = System.unique_integer([:positive])

    defaults = %{
      email: "inbox-test-#{n}@example.com",
      username: "inbox_test_#{n}",
      first_name: "Test",
      last_name: "User #{n}",
      hashed_password: "$2b$12$notarealhashjustenoughtosatisfythecolumn",
      is_active: true
    }

    TestRepo.insert!(struct(PhoenixKit.Users.Auth.User, Map.merge(defaults, attrs)))
  end

  @doc """
  A real `PhoenixKit.Users.Auth.Scope` for `user` holding exactly
  `permissions` — what the context functions that take a scope check with
  `Scope.can?/2`. Pair with `enable_inbox!/0`: `can?/2` also requires the
  module to be enabled.
  """
  def scope_for(user, permissions \\ ["inbox"]) do
    %Scope{
      user: user,
      authenticated?: true,
      cached_roles: [],
      cached_permissions: MapSet.new(permissions)
    }
  end

  @doc "Enables the module, which `Scope.can?/2` requires for every inbox key."
  def enable_inbox! do
    PhoenixKitInbox.enable_system()
    true = PhoenixKitInbox.enabled?()
    :ok
  end

  @doc """
  Inserts a shared mailbox owned by `owner` directly, bypassing the
  `inbox.manage_shared` check of `Mailboxes.create_shared_mailbox/2` — for
  tests about something else. Tests about creation go through the context.
  """
  def shared_mailbox_fixture(owner, attrs \\ %{}) do
    name = Map.get(attrs, :name, "Shared #{System.unique_integer([:positive])}")

    attrs =
      attrs
      |> Map.put(:name, name)
      |> Map.put_new(:slug, name)
      |> Map.merge(%{kind: "shared", owner_uuid: owner.uuid})

    %Mailbox{}
    |> Mailbox.changeset(attrs)
    |> TestRepo.insert!()
  end

  @doc """
  Inserts a grant directly, bypassing the scope check of
  `Mailboxes.grant_access/4` — for tests about something else.
  """
  def grant_fixture(mailbox, user, access) do
    %MailboxGrant{}
    |> MailboxGrant.changeset(%{
      mailbox_uuid: mailbox.uuid,
      user_uuid: user.uuid,
      access: access
    })
    |> TestRepo.insert!(
      on_conflict: {:replace, [:access, :updated_at]},
      conflict_target: [:mailbox_uuid, :user_uuid]
    )
  end

  @doc """
  Translates changeset errors into a `%{field => [message]}` map. Used
  by tests that assert on changeset error messages.
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
