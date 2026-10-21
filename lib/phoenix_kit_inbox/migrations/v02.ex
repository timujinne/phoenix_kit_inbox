defmodule PhoenixKitInbox.Migrations.V02 do
  @moduledoc """
  V02 — correspondence survives a user's deletion; shared addresses are unique.

  V01 cascaded a user's deletion through everything they touched: their
  personal mailbox (`owner_uuid ON DELETE CASCADE`), every message sent from
  it (`sender_mailbox_uuid ... CASCADE`) and with those, every recipient's
  copy. V02 makes the record permanent:

    * `mailboxes.owner_uuid` becomes nullable, `ON DELETE SET NULL` — the
      mailbox outlives its owner (`PhoenixKitInbox.before_user_delete/1`
      archives it or hands it to another admin first)
    * `messages.sender_mailbox_uuid` and `deliveries.mailbox_uuid` become
      `ON DELETE RESTRICT` — a mailbox with mail in it can't be deleted, only
      archived
    * a case-insensitive unique index on the `address` of shared mailboxes.
      Personal mailboxes are left out: their address is a snapshot of the
      owner's email, and two snapshots may legitimately collide after an
      email change. Existing collisions stop the migration with a message
      listing them — nothing is renamed automatically.

  Immutable once shipped, like V01.

  ## Prefix safety

  The V01 foreign keys carry Ecto's derived names, but nothing guarantees an
  install kept them, so each one is found in the catalog by **table, column
  and schema** (`pg_constraint` joined to `pg_class`, `pg_namespace` and
  `pg_attribute`) and dropped inside a server-side `DO` block — never by a
  bare name, which is unique per schema only and would match another
  prefix's constraint. The replacement gets an explicit name. The index name
  stays bare on `CREATE`.

  ## Down

  Refuses while any mailbox has lost its owner: restoring `NOT NULL` would
  need either deleting those mailboxes (and every message in them) or making
  up an owner, and a rollback has no business doing either.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  @mailboxes "phoenix_kit_inbox_mailboxes"
  @messages "phoenix_kit_inbox_messages"
  @deliveries "phoenix_kit_inbox_deliveries"
  @users "phoenix_kit_users"

  @address_index :phoenix_kit_inbox_mailboxes_shared_address_index

  @doc false
  def up(%{prefix: prefix} = _opts) do
    refuse_duplicate_shared_addresses(prefix)

    replace_fk(prefix, @mailboxes, "owner_uuid", @users, "SET NULL")

    execute(
      "ALTER TABLE #{Helpers.qualify_table(@mailboxes, prefix)} ALTER COLUMN owner_uuid DROP NOT NULL"
    )

    replace_fk(prefix, @messages, "sender_mailbox_uuid", @mailboxes, "RESTRICT")
    replace_fk(prefix, @deliveries, "mailbox_uuid", @mailboxes, "RESTRICT")

    create_if_not_exists(
      unique_index(:phoenix_kit_inbox_mailboxes, ["lower(address)"],
        name: @address_index,
        where: "kind = 'shared' AND address IS NOT NULL",
        prefix: prefix
      )
    )
  end

  @doc false
  def down(%{prefix: prefix} = _opts) do
    mailboxes = Helpers.qualify_table(@mailboxes, prefix)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{mailboxes} WHERE owner_uuid IS NULL) THEN
        RAISE EXCEPTION 'phoenix_kit_inbox V02 down: % mailbox(es) have no owner (their user was deleted); restoring NOT NULL would lose them. Assign an owner_uuid to each first.',
          (SELECT count(*) FROM #{mailboxes} WHERE owner_uuid IS NULL);
      END IF;
    END $$;
    """)

    drop_if_exists(index(:phoenix_kit_inbox_mailboxes, [], name: @address_index, prefix: prefix))

    replace_fk(prefix, @deliveries, "mailbox_uuid", @mailboxes, "CASCADE")
    replace_fk(prefix, @messages, "sender_mailbox_uuid", @mailboxes, "CASCADE")

    execute("ALTER TABLE #{mailboxes} ALTER COLUMN owner_uuid SET NOT NULL")
    replace_fk(prefix, @mailboxes, "owner_uuid", @users, "CASCADE")
  end

  # The unique index below would fail on its own, but with a bare
  # unique_violation that aborts the host's whole update migration and names
  # one value. Say what is wrong and what to do instead; never pick a winner.
  defp refuse_duplicate_shared_addresses(prefix) do
    mailboxes = Helpers.qualify_table(@mailboxes, prefix)

    execute("""
    DO $$
    DECLARE
      duplicates text;
    BEGIN
      SELECT string_agg(address, ', ' ORDER BY address) INTO duplicates
      FROM (
        SELECT lower(address) AS address
        FROM #{mailboxes}
        WHERE kind = 'shared' AND address IS NOT NULL
        GROUP BY lower(address)
        HAVING count(*) > 1
      ) collisions;

      IF duplicates IS NOT NULL THEN
        RAISE EXCEPTION 'phoenix_kit_inbox V02: shared mailboxes share an address (case-insensitive): %. Give each shared mailbox a distinct address (or clear one), then run the migration again.', duplicates;
      END IF;
    END $$;
    """)
  end

  # Drops whatever FK constraint(s) sit on `table.column` in this schema, then
  # adds one with Ecto's conventional name and the given delete rule.
  defp replace_fk(prefix, table, column, target, on_delete) do
    schema = prefix || "public"
    qualified = Helpers.qualify_table(table, prefix)

    execute("""
    DO $$
    DECLARE
      fk record;
    BEGIN
      FOR fk IN
        SELECT c.conname
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY (c.conkey)
        WHERE c.contype = 'f'
          AND n.nspname = '#{schema}'
          AND t.relname = '#{table}'
          AND a.attname = '#{column}'
      LOOP
        EXECUTE format('ALTER TABLE %I.%I DROP CONSTRAINT %I', '#{schema}', '#{table}', fk.conname);
      END LOOP;
    END $$;
    """)

    execute("""
    ALTER TABLE #{qualified}
      ADD CONSTRAINT #{table}_#{column}_fkey
      FOREIGN KEY (#{column}) REFERENCES #{Helpers.qualify_table(target, prefix)}(uuid)
      ON DELETE #{on_delete}
    """)
  end
end
