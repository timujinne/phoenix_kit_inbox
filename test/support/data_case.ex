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
  alias PhoenixKit.Modules.Storage
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
  Real Storage for a test: a local-disk bucket in a temp directory (the only
  enabled one) and a manual-mode Oban (Storage queues a variant job per stored file). Use as a
  `setup` callback in an `async: false` case — the bucket cache is global.
  """
  def storage_setup(_context \\ %{}) do
    :persistent_term.erase(:phoenix_kit_buckets_cache)
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "inbox_storage_#{n}")

    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "inbox-test-#{n}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    # Core seeds a "Local Storage" bucket at priv/media; switched off for the
    # test (the sandbox rolls this back) so no bytes land in the checkout.
    TestRepo.query!(
      "UPDATE phoenix_kit_buckets SET enabled = false WHERE uuid <> $1",
      [Ecto.UUID.dump!(bucket.uuid)]
    )

    ExUnit.Callbacks.start_supervised!(
      {Oban, name: Oban, repo: TestRepo, testing: :manual, queues: [], plugins: []}
    )

    ExUnit.Callbacks.on_exit(fn ->
      :persistent_term.erase(:phoenix_kit_buckets_cache)
      File.rm_rf(root)
    end)

    :ok
  end

  @doc """
  Stores `content` as a file uploaded by `user` — into Media unless
  `library_uuid:` names a library. `filename:` and `mime_type:` default to a
  text file.
  """
  def stored_file_fixture(user, content, opts \\ []) do
    filename = Keyword.get(opts, :filename, "note-#{System.unique_integer([:positive])}.txt")
    mime = Keyword.get(opts, :mime_type, "text/plain")
    source = Path.join(System.tmp_dir!(), "inbox_src_#{System.unique_integer([:positive])}")
    File.write!(source, content)
    hash = :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

    store_opts =
      [mime_type: mime] ++
        if(opts[:library_uuid], do: [library_uuid: opts[:library_uuid]], else: [])

    {:ok, file} =
      Storage.store_file_in_buckets(
        source,
        "document",
        user.uuid,
        hash,
        filename |> Path.extname() |> String.trim_leading("."),
        filename,
        store_opts
      )

    File.rm(source)
    file
  end

  @doc "Every Storage file row in `library_uuid`."
  def files_in_library(library_uuid) do
    import Ecto.Query

    TestRepo.all(
      from(f in Storage.File, where: f.library_uuid == ^library_uuid, order_by: f.inserted_at)
    )
  end

  @doc """
  A mail integration connection made through core's API, with fake
  credentials — nothing ever connects to it. `owner` is `:system` or
  `{:user, uuid}`.

  Options: `provider:` (default `"smtp"`), `name:`, `username:` (the login,
  which is the From address; default a fresh address), `setup: false` to
  leave it without credentials (not connected).
  """
  def mail_integration_fixture(owner, opts \\ []) do
    alias PhoenixKit.Integrations

    provider = Keyword.get(opts, :provider, "smtp")
    name = Keyword.get(opts, :name, "Mail #{System.unique_integer([:positive])}")

    {:ok, %{uuid: uuid}} = Integrations.add_connection(provider, name, nil, owner: owner)

    if Keyword.get(opts, :setup, true) do
      username =
        Keyword.get(opts, :username, "sender-#{System.unique_integer([:positive])}@example.com")

      setup =
        case provider do
          "smtp" ->
            %{
              "host" => "smtp.invalid",
              "port" => "587",
              "username" => username,
              "password" => "x"
            }

          "openrouter" ->
            %{"api_key" => "not-a-key"}

          "brevo_api" ->
            %{"api_key" => "not-a-key"}
        end

      {:ok, _} = Integrations.save_setup(uuid, setup, nil, owner: owner)
    end

    uuid
  end

  @doc """
  Points `PhoenixKitInbox.Outbound` at the recording test transport
  (`PhoenixKitInbox.Test.Outbound`), opens external sending
  (`inbox_external_enabled` on, `outbound_filter: :none`) and restores the
  previous configuration afterwards. A `setup` callback for `async: false`
  cases — the configuration is global. Every call to the transport arrives
  in the test process as `{:outbound, email, integration_uuid, opts}`.
  """
  def outbound_setup(_context \\ %{}) do
    keys = [:outbound, :test_outbound, :outbound_filter, :test_emails_enabled]
    saved = Map.new(keys, &{&1, Application.fetch_env(:phoenix_kit_inbox, &1)})

    Application.put_env(:phoenix_kit_inbox, :outbound, PhoenixKitInbox.Test.Outbound)
    Application.put_env(:phoenix_kit_inbox, :test_outbound, %{pid: self()})
    Application.put_env(:phoenix_kit_inbox, :outbound_filter, :none)
    {:ok, _} = PhoenixKitInbox.set_external_enabled(true)

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, value}} -> Application.put_env(:phoenix_kit_inbox, key, value)
        {key, :error} -> Application.delete_env(:phoenix_kit_inbox, key)
      end)
    end)

    :ok
  end

  @doc "What the test transport answers from now on: a result, or a 3-arity fun."
  def outbound_result(result) do
    config = Application.get_env(:phoenix_kit_inbox, :test_outbound, %{})
    Application.put_env(:phoenix_kit_inbox, :test_outbound, Map.put(config, :result, result))
  end

  @doc "Sets the host `outbound_filter` (`{module, fun}`, `:none` or `nil` for none)."
  def outbound_filter(filter) do
    if filter,
      do: Application.put_env(:phoenix_kit_inbox, :outbound_filter, filter),
      else: Application.delete_env(:phoenix_kit_inbox, :outbound_filter)
  end

  @doc "Makes the stand-in `PhoenixKit.Modules.Emails.enabled?/0` answer true."
  def emails_module_enabled! do
    Application.put_env(:phoenix_kit_inbox, :test_emails_enabled, true)
  end

  @doc """
  A `phoenix_kit_email_logs` row as `phoenix_kit_emails` writes one for a
  send tagged with `message_tags` (status `"sent"` unless given).
  """
  def email_log_fixture(message_tags, status \\ "sent") do
    message_id = "pk_" <> Ecto.UUID.generate()

    TestRepo.query!(
      """
      INSERT INTO phoenix_kit_email_logs
        (message_id, "to", "from", status, message_tags, inserted_at, updated_at)
      VALUES ($1, 'someone@example.com', 'sender@example.com', $2, $3, now(), now())
      """,
      [message_id, status, message_tags]
    )

    message_id
  end

  @doc """
  Waits for the external part of a send to finish: the
  `{:inbox_external_updated, message_uuid}` broadcast on the sending
  mailbox's topic, to which the caller must have subscribed
  (`PhoenixKitInbox.External.subscribe/1`) before sending.
  """
  def await_external(message_uuid) do
    ExUnit.Assertions.assert_receive({:inbox_external_updated, ^message_uuid}, 2_000)
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
