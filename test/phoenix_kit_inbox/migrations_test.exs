defmodule PhoenixKitInbox.MigrationsTest do
  @moduledoc """
  V02, V03 and V04 against a real database: the suite's own schema (migrated by
  `test_helper.exs` through the coordinator) and a scratch named schema, so
  the prefix-anchored changes are exercised outside `public`.
  """

  use PhoenixKitInbox.DataCase, async: false

  alias PhoenixKitInbox.Test.Repo, as: TestRepo

  @probe "inbox_v02_probe"
  # No migration lock: it would hold the sandbox connection in a transaction
  # while the migrator's task waits for the same connection.
  @migrator_opts [prefix: @probe, log: false, migration_lock: false]

  defmodule ProbeToV1 do
    @moduledoc false
    use Ecto.Migration
    def up, do: PhoenixKitInbox.Migrations.up(prefix: "inbox_v02_probe", version: 1)
    def down, do: :ok
  end

  defmodule ProbeToV2 do
    @moduledoc false
    use Ecto.Migration
    def up, do: PhoenixKitInbox.Migrations.up(prefix: "inbox_v02_probe", version: 2)
    def down, do: PhoenixKitInbox.Migrations.down(prefix: "inbox_v02_probe", version: 1)
  end

  defmodule ProbeToV3 do
    @moduledoc false
    use Ecto.Migration
    def up, do: PhoenixKitInbox.Migrations.up(prefix: "inbox_v02_probe", version: 3)
    def down, do: PhoenixKitInbox.Migrations.down(prefix: "inbox_v02_probe", version: 2)
  end

  defmodule ProbeToV4 do
    @moduledoc false
    use Ecto.Migration
    def up, do: PhoenixKitInbox.Migrations.up(prefix: "inbox_v02_probe", version: 4)
    def down, do: PhoenixKitInbox.Migrations.down(prefix: "inbox_v02_probe", version: 3)
  end

  test "the coordinator expects version 4" do
    assert PhoenixKitInbox.Migrations.current_version() == 4
  end

  describe "the suite's schema (public)" do
    test "is recorded at version 4" do
      assert version_comment("public") == "4"
    end

    test "identities go with their mailbox or owner and name no integration by FK" do
      assert fk_delete_rule("public", "phoenix_kit_inbox_identities", "mailbox_uuid") == "c"
      assert fk_delete_rule("public", "phoenix_kit_inbox_identities", "owner_uuid") == "c"
      assert fk_count("public", "phoenix_kit_inbox_identities", "integration_uuid") == 0
      assert column_nullable?("public", "phoenix_kit_inbox_identities", "mailbox_uuid")
      assert column_nullable?("public", "phoenix_kit_inbox_identities", "owner_uuid")
      refute column_nullable?("public", "phoenix_kit_inbox_identities", "integration_uuid")
    end

    test "an identity is either shared (no owner) or personal (an owner, no mailbox)" do
      owner = user_fixture()
      mailbox = insert_mailbox!("public", owner.uuid, "shared", "desk-ident", nil)

      insert_identity!("public", "shared", mailbox, nil)
      insert_identity!("public", "shared", nil, nil)
      insert_identity!("public", "personal", nil, owner.uuid)

      for {kind, mailbox_uuid, owner_uuid} <- [
            {"shared", nil, owner.uuid},
            {"personal", nil, nil},
            {"personal", mailbox, owner.uuid},
            {"other", nil, nil}
          ] do
        assert_raise Postgrex.Error, ~r/phoenix_kit_inbox_identities_kind_check/, fn ->
          TestRepo.transaction(fn ->
            insert_identity!("public", kind, mailbox_uuid, owner_uuid)
          end)
        end
      end
    end

    test "signatures go with their mailbox, one default each" do
      assert fk_delete_rule("public", "phoenix_kit_inbox_signatures", "mailbox_uuid") == "c"
      assert index_exists?("public", "phoenix_kit_inbox_signatures_default_index")

      owner = user_fixture()
      mailbox = insert_mailbox!("public", owner.uuid, "shared", "desk-sig", nil)
      insert_signature!("public", mailbox, true)
      insert_signature!("public", mailbox, false)

      assert_raise Postgrex.Error, ~r/phoenix_kit_inbox_signatures_default_index/, fn ->
        TestRepo.transaction(fn -> insert_signature!("public", mailbox, true) end)
      end
    end

    test "attachments go with their message and are looked up by file" do
      assert fk_delete_rule("public", "phoenix_kit_inbox_attachments", "message_uuid") == "c"
      assert fk_count("public", "phoenix_kit_inbox_attachments", "file_uuid") == 0
      assert index_exists?("public", "phoenix_kit_inbox_attachments_message_index")
      assert index_exists?("public", "phoenix_kit_inbox_attachments_file_uuid_index")
      refute column_nullable?("public", "phoenix_kit_inbox_attachments", "flags")
      assert column_nullable?("public", "phoenix_kit_inbox_attachments", "source_file_uuid")
    end

    test "a mailbox owner is nullable and cleared when the user is deleted" do
      assert column_nullable?("public", "phoenix_kit_inbox_mailboxes", "owner_uuid")
      assert fk_delete_rule("public", "phoenix_kit_inbox_mailboxes", "owner_uuid") == "n"
    end

    test "messages and deliveries refuse to lose their mailbox" do
      assert fk_delete_rule("public", "phoenix_kit_inbox_messages", "sender_mailbox_uuid") == "r"
      assert fk_delete_rule("public", "phoenix_kit_inbox_deliveries", "mailbox_uuid") == "r"
    end

    test "shared-mailbox addresses are unique regardless of case" do
      owner = user_fixture()

      insert_mailbox!("public", owner.uuid, "shared", "desk-one", "Desk@Example.com")

      assert_raise Postgrex.Error, ~r/phoenix_kit_inbox_mailboxes_shared_address_index/, fn ->
        TestRepo.transaction(fn ->
          insert_mailbox!("public", owner.uuid, "shared", "desk-two", "desk@example.COM")
        end)
      end
    end

    test "personal mailboxes may share an address snapshot" do
      # A personal address is the owner's email at creation; a later email
      # change can make two snapshots collide, which must not block anything.
      a = user_fixture()
      b = user_fixture()

      insert_mailbox!("public", a.uuid, "user", "u-a-#{a.uuid}", "same@example.com")
      insert_mailbox!("public", b.uuid, "user", "u-b-#{b.uuid}", "same@example.com")
    end
  end

  describe "a named schema" do
    setup do
      TestRepo.query!("CREATE SCHEMA #{@probe}")
      TestRepo.query!("CREATE TABLE #{@probe}.phoenix_kit_users (uuid uuid PRIMARY KEY)")

      Ecto.Migrator.up(TestRepo, 1, ProbeToV1, @migrator_opts)
      :ok
    end

    test "V01 leaves the cascades V02 replaces" do
      assert version_comment(@probe) == "1"
      refute column_nullable?(@probe, "phoenix_kit_inbox_mailboxes", "owner_uuid")
      assert fk_delete_rule(@probe, "phoenix_kit_inbox_mailboxes", "owner_uuid") == "c"
      assert fk_delete_rule(@probe, "phoenix_kit_inbox_messages", "sender_mailbox_uuid") == "c"
      assert fk_delete_rule(@probe, "phoenix_kit_inbox_deliveries", "mailbox_uuid") == "c"
    end

    test "V02 changes the prefixed schema and leaves public alone" do
      Ecto.Migrator.up(TestRepo, 2, ProbeToV2, @migrator_opts)

      assert version_comment(@probe) == "2"
      assert column_nullable?(@probe, "phoenix_kit_inbox_mailboxes", "owner_uuid")
      assert fk_delete_rule(@probe, "phoenix_kit_inbox_mailboxes", "owner_uuid") == "n"
      assert fk_delete_rule(@probe, "phoenix_kit_inbox_messages", "sender_mailbox_uuid") == "r"
      assert fk_delete_rule(@probe, "phoenix_kit_inbox_deliveries", "mailbox_uuid") == "r"
      assert index_exists?(@probe, "phoenix_kit_inbox_mailboxes_shared_address_index")

      # Each column carries exactly one FK — the old one was dropped, not shadowed.
      assert fk_count(@probe, "phoenix_kit_inbox_messages", "sender_mailbox_uuid") == 1
      assert fk_count("public", "phoenix_kit_inbox_messages", "sender_mailbox_uuid") == 1
      assert fk_delete_rule("public", "phoenix_kit_inbox_messages", "sender_mailbox_uuid") == "r"
    end

    test "deleting a user keeps the correspondence of the prefixed install" do
      Ecto.Migrator.up(TestRepo, 2, ProbeToV2, @migrator_opts)

      user = Ecto.UUID.generate()
      TestRepo.query!("INSERT INTO #{@probe}.phoenix_kit_users (uuid) VALUES ($1)", [dump(user)])
      mailbox = insert_mailbox!(@probe, user, "user", "u-probe", nil)

      TestRepo.query!("DELETE FROM #{@probe}.phoenix_kit_users WHERE uuid = $1", [dump(user)])

      %{rows: [[owner]]} =
        TestRepo.query!(
          "SELECT owner_uuid FROM #{@probe}.phoenix_kit_inbox_mailboxes WHERE uuid = $1",
          [dump(mailbox)]
        )

      assert owner == nil
    end

    test "V02 refuses, naming them, when shared addresses already collide" do
      owner = Ecto.UUID.generate()
      TestRepo.query!("INSERT INTO #{@probe}.phoenix_kit_users (uuid) VALUES ($1)", [dump(owner)])
      insert_mailbox!(@probe, owner, "shared", "desk-a", "Desk@Example.com")
      insert_mailbox!(@probe, owner, "shared", "desk-b", "desk@example.com")
      insert_mailbox!(@probe, owner, "shared", "other", "other@example.com")

      error =
        assert_raise Postgrex.Error, fn ->
          Ecto.Migrator.up(TestRepo, 2, ProbeToV2, @migrator_opts)
        end

      assert Exception.message(error) =~ "share an address"
      assert Exception.message(error) =~ "desk@example.com"
      refute Exception.message(error) =~ "other@example.com"
      assert version_comment(@probe) == "1"
    end

    test "down to V01 restores the cascades" do
      Ecto.Migrator.up(TestRepo, 2, ProbeToV2, @migrator_opts)
      Ecto.Migrator.down(TestRepo, 2, ProbeToV2, @migrator_opts)

      assert version_comment(@probe) == "1"
      refute column_nullable?(@probe, "phoenix_kit_inbox_mailboxes", "owner_uuid")
      assert fk_delete_rule(@probe, "phoenix_kit_inbox_mailboxes", "owner_uuid") == "c"
      assert fk_delete_rule(@probe, "phoenix_kit_inbox_messages", "sender_mailbox_uuid") == "c"
      assert fk_delete_rule(@probe, "phoenix_kit_inbox_deliveries", "mailbox_uuid") == "c"
      refute index_exists?(@probe, "phoenix_kit_inbox_mailboxes_shared_address_index")
    end

    test "V03 adds the attachments table to the prefixed schema" do
      Ecto.Migrator.up(TestRepo, 3, ProbeToV3, @migrator_opts)

      assert version_comment(@probe) == "3"
      assert table_exists?(@probe, "phoenix_kit_inbox_attachments")
      assert fk_delete_rule(@probe, "phoenix_kit_inbox_attachments", "message_uuid") == "c"
      assert index_exists?(@probe, "phoenix_kit_inbox_attachments_message_index")
    end

    test "down to V02 drops the attachments table and nothing else" do
      Ecto.Migrator.up(TestRepo, 3, ProbeToV3, @migrator_opts)
      Ecto.Migrator.down(TestRepo, 3, ProbeToV3, @migrator_opts)

      assert version_comment(@probe) == "2"
      refute table_exists?(@probe, "phoenix_kit_inbox_attachments")
      assert table_exists?(@probe, "phoenix_kit_inbox_messages")
      assert table_exists?("public", "phoenix_kit_inbox_attachments")
    end

    test "V04 adds identities and signatures to the prefixed schema" do
      Ecto.Migrator.up(TestRepo, 4, ProbeToV4, @migrator_opts)

      assert version_comment(@probe) == "4"
      assert table_exists?(@probe, "phoenix_kit_inbox_identities")
      assert table_exists?(@probe, "phoenix_kit_inbox_signatures")
      assert fk_delete_rule(@probe, "phoenix_kit_inbox_identities", "mailbox_uuid") == "c"
      assert fk_delete_rule(@probe, "phoenix_kit_inbox_identities", "owner_uuid") == "c"
      assert fk_delete_rule(@probe, "phoenix_kit_inbox_signatures", "mailbox_uuid") == "c"
      assert index_exists?(@probe, "phoenix_kit_inbox_signatures_default_index")
      assert index_exists?(@probe, "phoenix_kit_inbox_identities_mailbox_uuid_index")
      assert index_exists?(@probe, "phoenix_kit_inbox_identities_owner_uuid_index")
    end

    test "down to V03 drops identities and signatures and nothing else" do
      Ecto.Migrator.up(TestRepo, 4, ProbeToV4, @migrator_opts)
      Ecto.Migrator.down(TestRepo, 4, ProbeToV4, @migrator_opts)

      assert version_comment(@probe) == "3"
      refute table_exists?(@probe, "phoenix_kit_inbox_identities")
      refute table_exists?(@probe, "phoenix_kit_inbox_signatures")
      assert table_exists?(@probe, "phoenix_kit_inbox_attachments")
      assert table_exists?("public", "phoenix_kit_inbox_identities")
    end

    test "down refuses while a mailbox has lost its owner" do
      Ecto.Migrator.up(TestRepo, 2, ProbeToV2, @migrator_opts)
      insert_mailbox!(@probe, nil, "user", "u-orphan", nil)

      assert_raise Postgrex.Error, ~r/owner/, fn ->
        Ecto.Migrator.down(TestRepo, 2, ProbeToV2, @migrator_opts)
      end
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp version_comment(schema) do
    %{rows: [[comment]]} =
      TestRepo.query!(
        """
        SELECT obj_description(c.oid, 'pg_class')
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname = 'phoenix_kit_inbox_mailboxes' AND n.nspname = $1
        """,
        [schema]
      )

    comment
  end

  defp column_nullable?(schema, table, column) do
    %{rows: [[nullable]]} =
      TestRepo.query!(
        """
        SELECT is_nullable FROM information_schema.columns
        WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
        """,
        [schema, table, column]
      )

    nullable == "YES"
  end

  defp fk_rows(schema, table, column) do
    TestRepo.query!(
      """
      SELECT c.confdeltype
      FROM pg_constraint c
      JOIN pg_class t ON t.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
      JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY (c.conkey)
      WHERE c.contype = 'f' AND n.nspname = $1 AND t.relname = $2 AND a.attname = $3
      """,
      [schema, table, column]
    ).rows
  end

  defp fk_delete_rule(schema, table, column) do
    [[rule]] = fk_rows(schema, table, column)
    rule
  end

  defp fk_count(schema, table, column), do: length(fk_rows(schema, table, column))

  defp index_exists?(schema, name) do
    %{rows: [[exists]]} =
      TestRepo.query!(
        "SELECT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = $1 AND indexname = $2)",
        [schema, name]
      )

    exists
  end

  defp table_exists?(schema, table) do
    %{rows: [[exists]]} =
      TestRepo.query!(
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = $2)",
        [schema, table]
      )

    exists
  end

  defp insert_mailbox!(schema, owner_uuid, kind, slug, address) do
    uuid = Ecto.UUID.generate()

    TestRepo.query!(
      """
      INSERT INTO #{schema}.phoenix_kit_inbox_mailboxes
        (uuid, name, slug, address, kind, owner_uuid, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, now(), now())
      """,
      [dump(uuid), slug, slug, address, kind, owner_uuid && dump(owner_uuid)]
    )

    uuid
  end

  defp insert_identity!(schema, kind, mailbox_uuid, owner_uuid) do
    TestRepo.query!(
      """
      INSERT INTO #{schema}.phoenix_kit_inbox_identities
        (uuid, kind, mailbox_uuid, owner_uuid, label, integration_uuid, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, 'Desk', $5, now(), now())
      """,
      [
        dump(Ecto.UUID.generate()),
        kind,
        mailbox_uuid && dump(mailbox_uuid),
        owner_uuid && dump(owner_uuid),
        dump(Ecto.UUID.generate())
      ]
    )
  end

  defp insert_signature!(schema, mailbox_uuid, default?) do
    TestRepo.query!(
      """
      INSERT INTO #{schema}.phoenix_kit_inbox_signatures
        (uuid, mailbox_uuid, label, body, is_default, inserted_at, updated_at)
      VALUES ($1, $2, 'Sig', 'Body', $3, now(), now())
      """,
      [dump(Ecto.UUID.generate()), dump(mailbox_uuid), default?]
    )
  end

  defp dump(uuid), do: Ecto.UUID.dump!(uuid)
end
