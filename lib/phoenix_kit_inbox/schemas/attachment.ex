defmodule PhoenixKitInbox.Schemas.Attachment do
  @moduledoc """
  One file attached to a message — a reference, not the bytes.

  `file_uuid` is a file in Storage, always a snapshot in the module's hidden
  library (see `PhoenixKitInbox.Attachments`), so what was sent does not
  change when the file it was copied from is later edited or deleted.
  `source_file_uuid` records where the snapshot was copied from, for
  reference only. A forwarded file keeps its `file_uuid`: two rows may name
  the same snapshot.

  `flags` is a map the host's server code sets (`attachment_flags:` and
  `attachments_data:` in `Messages.send_message/4`) and the host's
  `attachment_policy` reads; `changeset/2` does not cast it — the module
  puts it explicitly — and a forward copies it.

  Tables are created by `PhoenixKitInbox.Migrations`, never by this schema.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{}

  schema "phoenix_kit_inbox_attachments" do
    field(:message_uuid, UUIDv7)
    field(:file_uuid, UUIDv7)
    field(:source_file_uuid, UUIDv7)
    field(:filename, :string)
    field(:content_type, :string)
    field(:size_bytes, :integer, default: 0)
    field(:position, :integer, default: 0)
    field(:flags, :map, default: %{})

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [
      :message_uuid,
      :file_uuid,
      :source_file_uuid,
      :filename,
      :content_type,
      :size_bytes,
      :position
    ])
    |> validate_required([:message_uuid, :file_uuid, :filename])
    |> validate_length(:filename, max: 255)
    |> validate_number(:size_bytes, greater_than_or_equal_to: 0)
  end
end
