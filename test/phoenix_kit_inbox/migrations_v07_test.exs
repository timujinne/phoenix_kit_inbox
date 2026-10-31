defmodule PhoenixKitInbox.MigrationsV07Test do
  @moduledoc """
  V07 — message links, send keys and the identity `personalize_from_name`
  flag: the suite's own schema (migrated by `test_helper.exs`) and a scratch
  named schema for `down`.
  """

  use PhoenixKitInbox.DataCase, async: false

  alias PhoenixKitInbox.Schemas.Identity
  alias PhoenixKitInbox.Schemas.Link
  alias PhoenixKitInbox.Schemas.SendKey
  alias PhoenixKitInbox.Test.Repo, as: TestRepo

  @probe "inbox_v07_probe"
  # No migration lock: it would hold the sandbox connection in a transaction
  # while the migrator's task waits for the same connection.
  @migrator_opts [prefix: @probe, log: false, migration_lock: false]

  defmodule ProbeToV7 do
    @moduledoc false
    use Ecto.Migration
    def up, do: PhoenixKitInbox.Migrations.up(prefix: "inbox_v07_probe", version: 7)
    def down, do: PhoenixKitInbox.Migrations.down(prefix: "inbox_v07_probe", version: 6)
  end

  @links "phoenix_kit_inbox_message_links"
  @keys "phoenix_kit_inbox_send_keys"
  @identities "phoenix_kit_inbox_identities"

  describe "up (the suite's schema, public)" do
    test "up creates both tables and the column" do
      assert version_comment("public") == "7"
      assert table_exists?("public", @links)
      assert table_exists?("public", @keys)

      assert fk_delete_rule("public", @links, "message_uuid") == "c"
      assert fk_delete_rule("public", @links, "linked_by_user_uuid") == "n"
      assert fk_delete_rule("public", @keys, "message_uuid") == "c"

      refute column_nullable?("public", @links, "kind")
      refute column_nullable?("public", @links, "ref")
      refute column_nullable?("public", @links, "source")
      assert column_nullable?("public", @links, "linked_by_user_uuid")
      assert column_length("public", @links, "kind") == 64
      assert column_length("public", @links, "ref") == 255
      refute column_nullable?("public", @keys, "key")

      assert index_exists?(
               "public",
               "phoenix_kit_inbox_message_links_message_uuid_kind_ref_index"
             )

      assert index_exists?("public", "phoenix_kit_inbox_message_links_kind_ref_index")
      assert index_exists?("public", "phoenix_kit_inbox_message_links_message_uuid_index")
      assert index_exists?("public", "phoenix_kit_inbox_send_keys_key_index")

      refute column_nullable?("public", @identities, "personalize_from_name")
      assert column_default("public", @identities, "personalize_from_name") == "false"
    end

    test "duplicate (message, kind, ref) rejected" do
      message = message_fixture()
      insert_link!(message, "order", "A1", "host")
      insert_link!(message, "order", "A2", "host")
      insert_link!(message, "invoice", "A1", "host")

      assert_raise Postgrex.Error,
                   ~r/phoenix_kit_inbox_message_links_message_uuid_kind_ref_index/,
                   fn ->
                     TestRepo.transaction(fn ->
                       insert_link!(message, "order", "A1", "subject")
                     end)
                   end

      assert_raise Postgrex.Error, ~r/message_links_source_check/, fn ->
        TestRepo.transaction(fn -> insert_link!(message, "order", "A3", "guess") end)
      end
    end

    test "a send key is unique and goes with its message" do
      message = message_fixture()
      insert_key!("key-1", message)

      assert_raise Postgrex.Error, ~r/phoenix_kit_inbox_send_keys_key_index/, fn ->
        TestRepo.transaction(fn -> insert_key!("key-1", message) end)
      end

      insert_link!(message, "order", "A1", "host")
      TestRepo.query!("DELETE FROM phoenix_kit_inbox_messages WHERE uuid = $1", [dump(message)])

      assert count(@links) == 0
      assert count(@keys) == 0
    end

    test "deleting a user nilifies linked_by_user_uuid" do
      linker = user_fixture(%{inbox_member: false})
      message = message_fixture()
      insert_link!(message, "order", "A1", "manual", linker.uuid)

      TestRepo.query!("DELETE FROM phoenix_kit_users WHERE uuid = $1", [dump(linker.uuid)])

      assert %{rows: [[nil]]} =
               TestRepo.query!("SELECT linked_by_user_uuid FROM #{@links} WHERE ref = 'A1'")
    end

    test "the schemas read and write the tables" do
      message = message_fixture()

      link =
        TestRepo.insert!(%Link{
          message_uuid: message,
          kind: "order",
          ref: "A1",
          source: "host"
        })

      assert %Link{kind: "order", ref: "A1", source: "host"} = TestRepo.get!(Link, link.uuid)

      TestRepo.insert!(%SendKey{key: "k-1", message_uuid: message})
      assert [%SendKey{key: "k-1"}] = TestRepo.all(SendKey)

      assert Link.sources() == ~w(host thread subject manual)
    end
  end

  describe "down (a named schema)" do
    setup do
      TestRepo.query!("CREATE SCHEMA #{@probe}")
      TestRepo.query!("CREATE TABLE #{@probe}.phoenix_kit_users (uuid uuid PRIMARY KEY)")

      TestRepo.query!(
        "CREATE TABLE #{@probe}.phoenix_kit_user_roles (uuid uuid PRIMARY KEY, name varchar NOT NULL)"
      )

      TestRepo.query!(
        "CREATE TABLE #{@probe}.phoenix_kit_role_permissions (role_uuid uuid NOT NULL, module_key varchar NOT NULL)"
      )

      Ecto.Migrator.up(TestRepo, 1, ProbeToV7, @migrator_opts)
      :ok
    end

    test "up builds the prefixed schema, public untouched by it" do
      assert version_comment(@probe) == "7"
      assert table_exists?(@probe, @links)
      assert table_exists?(@probe, @keys)
      assert fk_delete_rule(@probe, @links, "message_uuid") == "c"
      assert fk_delete_rule(@probe, @links, "linked_by_user_uuid") == "n"
      assert fk_delete_rule(@probe, @keys, "message_uuid") == "c"
      assert index_exists?(@probe, "phoenix_kit_inbox_message_links_kind_ref_index")
      assert column_default(@probe, @identities, "personalize_from_name") == "false"
    end

    test "down removes tables and column" do
      Ecto.Migrator.down(TestRepo, 1, ProbeToV7, @migrator_opts)

      assert version_comment(@probe) == "6"
      refute table_exists?(@probe, @links)
      refute table_exists?(@probe, @keys)
      assert table_exists?(@probe, @identities)
      assert table_exists?(@probe, "phoenix_kit_inbox_identity_roles")
      refute column_exists?(@probe, @identities, "personalize_from_name")

      # The suite's own schema is untouched.
      assert table_exists?("public", @links)
      assert column_exists?("public", @identities, "personalize_from_name")
    end
  end

  describe "Identity.changeset/2" do
    test "identity changeset casts personalize_from_name" do
      base = %Identity{kind: "shared", integration_uuid: Ecto.UUID.generate()}

      assert %{changes: %{personalize_from_name: true}} =
               Identity.changeset(base, %{"label" => "Desk", "personalize_from_name" => "true"})

      assert Identity.changeset(base, %{"label" => "Desk"}).changes
             |> Map.has_key?(:personalize_from_name) == false

      assert %Identity{}.personalize_from_name == false
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp message_fixture do
    owner = user_fixture()
    mailbox = insert_mailbox!(owner.uuid)
    uuid = Ecto.UUID.generate()

    TestRepo.query!(
      """
      INSERT INTO phoenix_kit_inbox_messages
        (uuid, thread_uuid, sender_mailbox_uuid, status, inserted_at, updated_at)
      VALUES ($1, $1, $2, 'sent', now(), now())
      """,
      [dump(uuid), dump(mailbox)]
    )

    uuid
  end

  defp insert_mailbox!(owner_uuid) do
    uuid = Ecto.UUID.generate()
    slug = "v07-#{System.unique_integer([:positive])}"

    TestRepo.query!(
      """
      INSERT INTO phoenix_kit_inbox_mailboxes
        (uuid, name, slug, address, kind, owner_uuid, inserted_at, updated_at)
      VALUES ($1, $2, $2, NULL, 'user', $3, now(), now())
      """,
      [dump(uuid), slug, dump(owner_uuid)]
    )

    uuid
  end

  defp insert_link!(message, kind, ref, source, user \\ nil) do
    TestRepo.query!(
      """
      INSERT INTO #{@links} (message_uuid, kind, ref, source, linked_by_user_uuid, inserted_at)
      VALUES ($1, $2, $3, $4, $5, now())
      """,
      [dump(message), kind, ref, source, user && dump(user)]
    )
  end

  defp insert_key!(key, message) do
    TestRepo.query!(
      "INSERT INTO #{@keys} (key, message_uuid, inserted_at) VALUES ($1, $2, now())",
      [key, dump(message)]
    )
  end

  defp count(table), do: TestRepo.query!("SELECT count(*) FROM #{table}").rows |> hd() |> hd()

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

  defp column_row(schema, table, column) do
    TestRepo.query!(
      """
      SELECT is_nullable, column_default, character_maximum_length
      FROM information_schema.columns
      WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
      """,
      [schema, table, column]
    ).rows
  end

  defp column_exists?(schema, table, column), do: column_row(schema, table, column) != []

  defp column_nullable?(schema, table, column),
    do: hd(hd(column_row(schema, table, column))) == "YES"

  defp column_default(schema, table, column),
    do: column_row(schema, table, column) |> hd() |> Enum.at(1)

  defp column_length(schema, table, column),
    do: column_row(schema, table, column) |> hd() |> Enum.at(2)

  defp fk_delete_rule(schema, table, column) do
    %{rows: [[rule]]} =
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
      )

    rule
  end

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

  defp dump(uuid), do: Ecto.UUID.dump!(uuid)
end
