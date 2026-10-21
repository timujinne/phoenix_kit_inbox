defmodule PhoenixKitInbox.Migrations.V04 do
  @moduledoc """
  V04 — sending identities and signatures.

  `phoenix_kit_inbox_identities` — who a message can be sent *as* outside the
  application: an email integration (`integration_uuid`, no FK — integrations
  are `phoenix_kit_settings` rows core owns) and the name shown beside its
  login address. `kind` is `"shared"` (a system integration, bound to a shared
  mailbox or to none) or `"personal"` (the owner's own integration). A CHECK
  keeps the two apart: a shared identity has no owner, a personal one has an
  owner and no mailbox. Both foreign keys cascade — an identity outliving its
  mailbox would turn into an unbound one, usable by everyone allowed to send
  externally, so it goes with the mailbox instead.

  `phoenix_kit_inbox_signatures` — a mailbox's signatures, Markdown, at most
  one default per mailbox (partial unique index); they go with the mailbox.

  Immutable once shipped, like V01–V03. Prefix-safe: bare index names on
  `CREATE`, `Helpers.uuid_v7_call/1` for the keys, every FK in the same prefix.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  @kind_check "phoenix_kit_inbox_identities_kind_check"

  @doc false
  def up(%{prefix: prefix} = _opts) do
    create_identities(prefix)
    create_signatures(prefix)
  end

  @doc false
  def down(%{prefix: prefix} = _opts) do
    drop_if_exists(table(:phoenix_kit_inbox_signatures, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_inbox_identities, prefix: prefix))
  end

  defp create_identities(prefix) do
    create_if_not_exists table(:phoenix_kit_inbox_identities,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid,
        primary_key: true,
        null: false,
        default: fragment(Helpers.uuid_v7_call(prefix))
      )

      add(:kind, :string, null: false)

      add(
        :mailbox_uuid,
        references(:phoenix_kit_inbox_mailboxes,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        )
      )

      add(
        :owner_uuid,
        references(:phoenix_kit_users,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        )
      )

      add(:label, :string, null: false)
      add(:from_name, :string)
      add(:integration_uuid, :uuid, null: false)
      add(:status, :string, null: false, default: "active")

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:phoenix_kit_inbox_identities, [:mailbox_uuid], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_inbox_identities, [:owner_uuid], prefix: prefix))

    add_kind_check(prefix)
  end

  # Looked up by name *and schema* before adding, so a re-run is a no-op and a
  # constraint of the same name in another prefix is never mistaken for it.
  defp add_kind_check(prefix) do
    schema = prefix || "public"
    table = "phoenix_kit_inbox_identities"

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
          AND t.relname = '#{table}'
          AND c.conname = '#{@kind_check}'
      ) THEN
        ALTER TABLE #{Helpers.qualify_table(table, prefix)}
          ADD CONSTRAINT #{@kind_check} CHECK (
            (kind = 'shared' AND owner_uuid IS NULL) OR
            (kind = 'personal' AND owner_uuid IS NOT NULL AND mailbox_uuid IS NULL)
          );
      END IF;
    END $$;
    """)
  end

  defp create_signatures(prefix) do
    create_if_not_exists table(:phoenix_kit_inbox_signatures,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid,
        primary_key: true,
        null: false,
        default: fragment(Helpers.uuid_v7_call(prefix))
      )

      add(
        :mailbox_uuid,
        references(:phoenix_kit_inbox_mailboxes,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(:label, :string, null: false)
      add(:body, :text, null: false, default: "")
      add(:is_default, :boolean, null: false, default: false)

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:phoenix_kit_inbox_signatures, [:mailbox_uuid], prefix: prefix))

    create_if_not_exists(
      unique_index(:phoenix_kit_inbox_signatures, [:mailbox_uuid],
        name: :phoenix_kit_inbox_signatures_default_index,
        where: "is_default",
        prefix: prefix
      )
    )
  end
end
