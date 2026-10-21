defmodule PhoenixKitInbox.Migrations.V03 do
  @moduledoc """
  V03 — message attachments.

  One row per file attached to a message. The bytes are not here: `file_uuid`
  names a file in Storage — a snapshot in the module's own hidden library
  (`PhoenixKitInbox.Attachments`) — so a message stores references, and a
  file forwarded on shares the row's `file_uuid` instead of being copied
  again. `file_uuid` and `source_file_uuid` carry no foreign key on purpose:
  Storage owns those rows, and the record of what was sent must not depend on
  it keeping them.

  Rows go with their message (`ON DELETE CASCADE`) — which only ever happens
  to a discarded draft: sent messages are never deleted.

  Immutable once shipped, like V01 and V02. Prefix-safe: bare index names on
  `CREATE`, `Helpers.uuid_v7_call/1` for the key, the FK in the same prefix.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  @doc false
  def up(%{prefix: prefix} = _opts) do
    create_if_not_exists table(:phoenix_kit_inbox_attachments,
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

      add(:file_uuid, :uuid, null: false)
      add(:source_file_uuid, :uuid)
      add(:filename, :string, null: false)
      add(:content_type, :string)
      add(:size_bytes, :bigint, null: false, default: 0)
      add(:position, :integer, null: false, default: 0)
      add(:flags, :map, null: false, default: %{})

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # A message's attachments in order — the reading pane and every send.
    create_if_not_exists(
      index(:phoenix_kit_inbox_attachments, [:message_uuid, :position],
        name: :phoenix_kit_inbox_attachments_message_index,
        prefix: prefix
      )
    )

    # "Who else holds this file?" — forwarding and snapshot clean-up.
    create_if_not_exists(index(:phoenix_kit_inbox_attachments, [:file_uuid], prefix: prefix))
  end

  @doc false
  def down(%{prefix: prefix} = _opts) do
    drop_if_exists(table(:phoenix_kit_inbox_attachments, prefix: prefix))
  end
end
