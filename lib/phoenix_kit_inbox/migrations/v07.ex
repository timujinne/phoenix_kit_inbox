defmodule PhoenixKitInbox.Migrations.V07 do
  @moduledoc """
  V07 — links from messages to objects of the host, idempotent send keys, and
  the sender-name flag of a shared identity.

  `phoenix_kit_inbox_message_links` — one row per `(message, kind, ref)`: the
  `kind` (at most 64 characters) and `ref` (at most 255) name an object the
  host owns — the module neither knows nor checks what they point to. `source`
  says how the link came about: `host` (given by the host when sending),
  `thread` (inherited along the conversation), `subject` (found in the
  subject by a host resolver) or `manual` (a person linked it); a CHECK keeps
  it to those. `linked_by_user_uuid` is the person who linked it, cleared
  (`ON DELETE SET NULL`) when that user is deleted — the link outlives them.
  Rows go with their message. Unique on `(message_uuid, kind, ref)`; indexed
  by `(kind, ref)` for "the mail of this object" and by `message_uuid` for the
  cascade and "the objects of this message".

  `phoenix_kit_inbox_send_keys` — a key the host gave a send so that repeating
  it answers with the same message instead of sending twice. Unique on `key`;
  the row goes with its message. Indexed by `inserted_at` for the purge of old
  keys and by `message_uuid` for the cascade.

  `phoenix_kit_inbox_identities.personalize_from_name` — whether a shared
  identity puts the sender's own name into the From name. Off for every
  existing row.

  `down` drops both tables and the column.

  Immutable once shipped, like V01–V06. Prefix-safe: bare index names on
  `CREATE`, `Helpers.uuid_v7_call/1` for the key, every FK in the same prefix,
  the CHECK looked up by name and schema.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  @links "phoenix_kit_inbox_message_links"

  @doc false
  def up(%{prefix: prefix} = _opts) do
    create_if_not_exists table(:phoenix_kit_inbox_message_links,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid,
        primary_key: true,
        null: false,
        default: fragment(Helpers.uuid_v7_call(prefix))
      )

      add(
        :message_uuid,
        references(:phoenix_kit_inbox_messages,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(:kind, :string, size: 64, null: false)
      add(:ref, :string, size: 255, null: false)
      add(:source, :string, null: false)

      add(
        :linked_by_user_uuid,
        references(:phoenix_kit_users,
          column: :uuid,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: prefix
        )
      )

      add(:inserted_at, :utc_datetime, null: false, default: fragment("now()"))
    end

    create_if_not_exists(
      unique_index(:phoenix_kit_inbox_message_links, [:message_uuid, :kind, :ref], prefix: prefix)
    )

    create_if_not_exists(index(:phoenix_kit_inbox_message_links, [:kind, :ref], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_inbox_message_links, [:message_uuid], prefix: prefix))

    add_check(
      prefix,
      "#{@links}_source_check",
      "source IN ('host', 'thread', 'subject', 'manual')"
    )

    create_if_not_exists table(:phoenix_kit_inbox_send_keys, primary_key: false, prefix: prefix) do
      add(:key, :string, null: false)

      add(
        :message_uuid,
        references(:phoenix_kit_inbox_messages,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(:inserted_at, :utc_datetime, null: false, default: fragment("now()"))
    end

    create_if_not_exists(unique_index(:phoenix_kit_inbox_send_keys, [:key], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_inbox_send_keys, [:inserted_at], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_inbox_send_keys, [:message_uuid], prefix: prefix))

    alter table(:phoenix_kit_inbox_identities, prefix: prefix) do
      add_if_not_exists(:personalize_from_name, :boolean, null: false, default: false)
    end
  end

  @doc false
  def down(%{prefix: prefix} = _opts) do
    alter table(:phoenix_kit_inbox_identities, prefix: prefix) do
      remove_if_exists(:personalize_from_name, :boolean)
    end

    drop_if_exists(table(:phoenix_kit_inbox_send_keys, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_inbox_message_links, prefix: prefix))
  end

  # Looked up by name *and schema* before adding, so a re-run is a no-op and a
  # constraint of the same name in another prefix is never mistaken for it.
  defp add_check(prefix, name, condition) do
    schema = prefix || "public"

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.contype = 'c'
          AND n.nspname = '#{schema}'
          AND t.relname = '#{@links}'
          AND c.conname = '#{name}'
      ) THEN
        ALTER TABLE #{Helpers.qualify_table(@links, prefix)}
          ADD CONSTRAINT #{name} CHECK (#{condition});
      END IF;
    END $$;
    """)
  end
end
