defmodule PhoenixKitInbox.Schemas.Signature do
  @moduledoc """
  A signature of a mailbox — Markdown, inserted at the end of a message being
  written (`PhoenixKitInbox.Signatures`). At most one per mailbox is the
  default (a partial unique index backs `Signatures` clearing the others).

  `mailbox_uuid` is put by the context, never cast from a form. Tables are
  created by `PhoenixKitInbox.Migrations`, never by this schema.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @max_body 10_000

  @type t :: %__MODULE__{}

  schema "phoenix_kit_inbox_signatures" do
    field(:mailbox_uuid, UUIDv7)
    field(:label, :string)
    field(:body, :string, default: "")
    field(:is_default, :boolean, default: false)

    timestamps(type: :utc_datetime)
  end

  @doc "The longest body a signature may have, in characters."
  @spec max_body() :: pos_integer()
  def max_body, do: @max_body

  @doc "Changeset for the fields a form may set: `label`, `body`, `is_default`."
  def changeset(signature, attrs) do
    signature
    |> cast(attrs, [:label, :body, :is_default], empty_values: [])
    |> update_change(:label, &String.trim/1)
    |> update_change(:body, &(&1 |> to_string() |> String.trim_trailing()))
    |> validate_required([:mailbox_uuid, :label])
    |> validate_length(:label, min: 1, max: 255)
    |> validate_length(:body, max: @max_body)
    |> unique_constraint(:is_default, name: :phoenix_kit_inbox_signatures_default_index)
  end
end
