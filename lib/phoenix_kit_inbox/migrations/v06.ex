defmodule PhoenixKitInbox.Migrations.V06 do
  @moduledoc """
  V06 — the roles a shared sender is open to.

  `phoenix_kit_inbox_identity_roles` — one row per role that may send as a
  shared identity bound to no mailbox (the common sender for personal
  mailboxes): `identity_uuid` and `role_uuid`, unique together, both
  cascading — a row goes with its identity and with its role. Indexed by
  `role_uuid` as well, for the cascade and for "the senders of these roles".
  The roles only narrow: a user still needs `inbox.send_external`
  (`PhoenixKitInbox.Identities`).

  Data, only on the step 5 → 6: every such identity is given the roles that
  hold `inbox.send_external` or the superadmin key `"*"`, Owner excepted
  (Owner may always send as them, without a row) — so nobody who could send
  as one before the update loses it. An `up` at version 6 never runs it
  again, and roles taken away stay away.

  `down` drops the table and the roles chosen with it; a later `up` seeds
  again from the roles holding `inbox.send_external` then, not from what
  had been chosen.

  Immutable once shipped, like V01–V05. Prefix-safe: bare index names on
  `CREATE`, both FKs in the same prefix, the seed's tables qualified with
  `Helpers.qualify_table/2`.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  @table "phoenix_kit_inbox_identity_roles"

  @doc false
  def up(%{prefix: prefix} = _opts) do
    create_if_not_exists table(:phoenix_kit_inbox_identity_roles,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(
        :identity_uuid,
        references(:phoenix_kit_inbox_identities,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(
        :role_uuid,
        references(:phoenix_kit_user_roles,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(:inserted_at, :utc_datetime, null: false, default: fragment("now()"))
    end

    create_if_not_exists(
      unique_index(:phoenix_kit_inbox_identity_roles, [:identity_uuid, :role_uuid],
        prefix: prefix
      )
    )

    create_if_not_exists(index(:phoenix_kit_inbox_identity_roles, [:role_uuid], prefix: prefix))

    seed(prefix)
  end

  @doc false
  def down(%{prefix: prefix} = _opts) do
    drop_if_exists(table(:phoenix_kit_inbox_identity_roles, prefix: prefix))
  end

  defp seed(prefix) do
    execute("""
    INSERT INTO #{Helpers.qualify_table(@table, prefix)} (identity_uuid, role_uuid, inserted_at)
    SELECT DISTINCT i.uuid, rp.role_uuid, now()
    FROM #{Helpers.qualify_table("phoenix_kit_inbox_identities", prefix)} i
    JOIN #{Helpers.qualify_table("phoenix_kit_role_permissions", prefix)} rp
      ON rp.module_key IN ('inbox.send_external', '*')
    JOIN #{Helpers.qualify_table("phoenix_kit_user_roles", prefix)} r
      ON r.uuid = rp.role_uuid AND r.name <> 'Owner'
    WHERE i.kind = 'shared' AND i.mailbox_uuid IS NULL
    ON CONFLICT DO NOTHING
    """)
  end
end
