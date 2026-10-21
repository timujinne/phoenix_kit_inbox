defmodule PhoenixKitInbox.Schemas.Mailbox do
  @moduledoc """
  A mailbox — the thing messages are delivered to.

  Two kinds, both stored in this one table:

    * `"user"` — a personal mailbox owned by exactly one PhoenixKit user.
      `owner_uuid` is set and there is at most one per user (enforced by a
      partial unique index in the migration).
    * `"shared"` — a team mailbox (`support`, `sales`, …). `owner_uuid` is the
      user who created it; everyone else reaches it through a
      `PhoenixKitInbox.Schemas.MailboxGrant`.

  `owner_uuid` is required on creation but nullable in the table (V02): when
  the owner's account is deleted the mailbox and its mail stay, ownerless and
  archived (see `PhoenixKitInbox.before_user_delete/1`).

  A shared mailbox's `address` is unique regardless of case and may not be a
  user's login email (`PhoenixKitInbox.Mailboxes` checks the latter on save).

  `address` is the mailbox's identity inside the app (`"support@example.com"`,
  or the owner's login email for a user mailbox). Nothing is sent *from*
  this address — external mail goes out as a sending identity, through
  `PhoenixKitInbox.Outbound` — it is a display/lookup handle, a Reply-To
  choice, and where a shared mailbox's email nudge goes.

  Tables are created by `PhoenixKitInbox.Migrations`, never by this schema.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @kinds ~w(user shared)
  @statuses ~w(active archived deleted)

  @type t :: %__MODULE__{}

  schema "phoenix_kit_inbox_mailboxes" do
    field(:name, :string)
    field(:slug, :string)
    field(:address, :string)
    field(:kind, :string, default: "user")
    field(:status, :string, default: "active")
    field(:owner_uuid, UUIDv7)
    field(:settings, :map, default: %{})

    timestamps(type: :utc_datetime)
  end

  @doc "Valid values for the `kind` column."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "Valid values for the `status` column."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc false
  def changeset(mailbox, attrs) do
    mailbox
    |> cast(attrs, [:name, :slug, :address, :kind, :status, :owner_uuid, :settings])
    |> validate_required([:name, :slug, :kind, :owner_uuid])
    |> update_change(:slug, &normalize_slug/1)
    |> update_change(:address, &normalize_address/1)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:name, max: 255)
    |> validate_format(:slug, ~r/\A[a-z0-9][a-z0-9-]*\z/,
      message: "must be lowercase letters, digits and hyphens"
    )
    |> unique_constraint(:slug, name: :phoenix_kit_inbox_mailboxes_slug_index)
    |> unique_constraint(:address,
      name: :phoenix_kit_inbox_mailboxes_shared_address_index,
      message: "is already used by another shared mailbox"
    )
    |> unique_constraint(:owner_uuid, name: :phoenix_kit_inbox_mailboxes_user_owner_index)
  end

  defp normalize_slug(nil), do: nil

  defp normalize_slug(slug) do
    slug
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp normalize_address(nil), do: nil
  defp normalize_address(address), do: address |> String.trim() |> String.downcase()
end
