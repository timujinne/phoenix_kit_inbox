defmodule PhoenixKitInbox.Schemas.MailboxGrant do
  @moduledoc """
  Grants a user access to a mailbox they do not own.

  Modelled on `phoenix_kit_calendar`'s per-calendar view/edit permissions: the
  module-level `"inbox"` permission decides *whether a user can use Inbox at
  all*, and a grant decides *which mailboxes they see inside it*. A user's own
  `kind: "user"` mailbox needs no grant — ownership implies `"admin"` access.

  Access levels, in increasing order:

    * `"read"`  — open the mailbox, read messages, mark seen/starred
    * `"write"` — the above, plus compose and send as the mailbox, move/trash
    * `"admin"` — the above, plus manage the mailbox's own grants

  Tables are created by `PhoenixKitInbox.Migrations`, never by this schema.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @levels ~w(read write admin)
  @level_rank %{"read" => 1, "write" => 2, "admin" => 3}

  @type t :: %__MODULE__{}

  schema "phoenix_kit_inbox_mailbox_grants" do
    field(:mailbox_uuid, UUIDv7)
    field(:user_uuid, UUIDv7)
    field(:access, :string, default: "read")
    field(:granted_by_uuid, UUIDv7)

    timestamps(type: :utc_datetime)
  end

  @doc "Valid access levels, weakest first."
  @spec levels() :: [String.t()]
  def levels, do: @levels

  @doc """
  Whether `held` satisfies `required`.

      iex> PhoenixKitInbox.Schemas.MailboxGrant.covers?("admin", "write")
      true
      iex> PhoenixKitInbox.Schemas.MailboxGrant.covers?("read", "write")
      false
  """
  @spec covers?(String.t() | nil, String.t()) :: boolean()
  def covers?(nil, _required), do: false

  def covers?(held, required) do
    Map.get(@level_rank, held, 0) >= Map.get(@level_rank, required, 0)
  end

  @doc false
  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [:mailbox_uuid, :user_uuid, :access, :granted_by_uuid])
    |> validate_required([:mailbox_uuid, :user_uuid, :access])
    |> validate_inclusion(:access, @levels)
    |> foreign_key_constraint(:user_uuid)
    |> unique_constraint([:mailbox_uuid, :user_uuid],
      name: :phoenix_kit_inbox_mailbox_grants_mailbox_user_index
    )
  end
end
