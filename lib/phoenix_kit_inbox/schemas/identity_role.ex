defmodule PhoenixKitInbox.Schemas.IdentityRole do
  @moduledoc """
  A role a shared identity bound to no mailbox (the common sender) is open
  to. Written and read only by `PhoenixKitInbox.Identities`; the row goes
  with its identity and with its role. Tables are created by
  `PhoenixKitInbox.Migrations`, never by this schema.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @primary_key false
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{}

  schema "phoenix_kit_inbox_identity_roles" do
    field(:identity_uuid, UUIDv7)
    field(:role_uuid, UUIDv7)
    field(:inserted_at, :utc_datetime)
  end
end
