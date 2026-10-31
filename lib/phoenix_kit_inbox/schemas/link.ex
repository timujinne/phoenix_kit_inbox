defmodule PhoenixKitInbox.Schemas.Link do
  @moduledoc """
  A link from a message to an object of the host application, named by a
  `kind` and a `ref` the module neither knows nor checks. One row per
  `(message, kind, ref)`.

  `source` says how it came about:

    * `"host"` — given by the host when sending
    * `"thread"` — inherited along the conversation
    * `"subject"` — found in the subject by a host resolver
    * `"manual"` — linked by a person (`linked_by_user_uuid`)

  The row goes with its message; `linked_by_user_uuid` is cleared when that
  user is deleted. Tables are created by `PhoenixKitInbox.Migrations`, never
  by this schema.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @sources ~w(host thread subject manual)

  @type t :: %__MODULE__{}

  schema "phoenix_kit_inbox_message_links" do
    field(:message_uuid, UUIDv7)
    field(:kind, :string)
    field(:ref, :string)
    field(:source, :string)
    field(:linked_by_user_uuid, UUIDv7)
    field(:inserted_at, :utc_datetime)
  end

  @doc "Valid values for the `source` column."
  @spec sources() :: [String.t()]
  def sources, do: @sources
end
