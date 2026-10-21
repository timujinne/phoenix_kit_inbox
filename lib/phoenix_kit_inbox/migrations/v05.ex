defmodule PhoenixKitInbox.Migrations.V05 do
  @moduledoc """
  V05 — external recipients.

  `phoenix_kit_inbox_external_recipients` — one row per address outside the
  application a message went to: its `role` (`to`, `cc`, `bcc`), the
  `address` and an optional display `name`, and how the send went —
  `status` `pending` (written with the message, before anything leaves),
  `sent` or `failed` (with `error`), `attempted_at`, and the
  `message_id` of the email log row when the host runs `phoenix_kit_emails`
  (`email_log_message_id`, no FK — that table belongs to another package).

  Rows go with their message (`ON DELETE CASCADE`), which only happens to a
  discarded draft; a draft never has any. Two CHECKs keep `role` and
  `status` to their values.

  Immutable once shipped, like V01–V04. Prefix-safe: bare index names on
  `CREATE`, `Helpers.uuid_v7_call/1` for the key, the FK in the same prefix,
  the CHECKs looked up by name and schema.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  @table "phoenix_kit_inbox_external_recipients"

  @doc false
  def up(%{prefix: prefix} = _opts) do
    create_if_not_exists table(:phoenix_kit_inbox_external_recipients,
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

      add(:role, :string, null: false)
      add(:address, :string, null: false)
      add(:name, :string)
      add(:status, :string, null: false, default: "pending")
      add(:error, :text)
      add(:email_log_message_id, :string)
      add(:attempted_at, :utc_datetime)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create_if_not_exists(
      index(:phoenix_kit_inbox_external_recipients, [:message_uuid], prefix: prefix)
    )

    add_check(prefix, "#{@table}_role_check", "role IN ('to', 'cc', 'bcc')")
    add_check(prefix, "#{@table}_status_check", "status IN ('pending', 'sent', 'failed')")
  end

  @doc false
  def down(%{prefix: prefix} = _opts) do
    drop_if_exists(table(:phoenix_kit_inbox_external_recipients, prefix: prefix))
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
          AND t.relname = '#{@table}'
          AND c.conname = '#{name}'
      ) THEN
        ALTER TABLE #{Helpers.qualify_table(@table, prefix)}
          ADD CONSTRAINT #{name} CHECK (#{condition});
      END IF;
    END $$;
    """)
  end
end
