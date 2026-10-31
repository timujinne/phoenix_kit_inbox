defmodule PhoenixKitInbox.Schemas.SendKey do
  @moduledoc """
  The key a host gave a send, so that repeating it answers with the message
  already sent instead of sending twice. `key` is unique; the row goes with
  its message. Tables are created by `PhoenixKitInbox.Migrations`, never by
  this schema.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @primary_key false
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{}

  schema "phoenix_kit_inbox_send_keys" do
    field(:key, :string)
    field(:message_uuid, UUIDv7)
    field(:inserted_at, :utc_datetime)
  end
end
