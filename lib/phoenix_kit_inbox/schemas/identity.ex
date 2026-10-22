defmodule PhoenixKitInbox.Schemas.Identity do
  @moduledoc """
  A sending identity — who a message goes out *as* when it leaves the
  application: an email integration and the name shown beside its address.

  The From **address** is not stored and never typed: it is the integration's
  login (`PhoenixKitInbox.Identities`), because a mail server refuses a From
  it does not own.

  Two kinds:

    * `"shared"` — a system integration (`owner: :system`), created by holders
      of `inbox.manage_shared`. Bound to a shared mailbox (`mailbox_uuid`:
      everyone with `"write"` on it may use it) or to none — then it is the
      common sender for personal mailboxes, used by holders of
      `inbox.send_external` with one of its roles in effect
      (`PhoenixKitInbox.Schemas.IdentityRole`; Owner always).
    * `"personal"` — the owner's own integration (`owner: {:user, owner_uuid}`),
      used only from the owner's personal mailbox.

  `status` is `"broken"` once a check found the integration gone,
  disconnected, not a mail provider, owned by someone else, or without a
  login address; the next passing check makes it `"active"` again.

  `kind`, `mailbox_uuid`, `owner_uuid`, `integration_uuid` and `status` are
  put by the context, never cast from a form. Tables are created by
  `PhoenixKitInbox.Migrations`, never by this schema.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @kinds ~w(shared personal)
  @statuses ~w(active broken)

  @type t :: %__MODULE__{}

  schema "phoenix_kit_inbox_identities" do
    field(:kind, :string)
    field(:mailbox_uuid, UUIDv7)
    field(:owner_uuid, UUIDv7)
    field(:label, :string)
    field(:from_name, :string)
    field(:integration_uuid, UUIDv7)
    field(:status, :string, default: "active")

    timestamps(type: :utc_datetime)
  end

  @doc "Valid values for the `kind` column."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "Valid values for the `status` column."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Changeset for the fields a form may set: `label` and `from_name`."
  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:label, :from_name])
    |> update_change(:label, &trim/1)
    |> update_change(:from_name, &trim/1)
    |> validate_required([:label, :kind, :integration_uuid])
    |> validate_length(:label, max: 255)
    |> validate_length(:from_name, max: 255)
    |> validate_format(:from_name, ~r/\A[^\r\n<>"]*\z/,
      message: "can't contain line breaks, quotes or angle brackets"
    )
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> check_constraint(:kind, name: :phoenix_kit_inbox_identities_kind_check)
  end

  # A field cleared in a form arrives as `nil`: left for `validate_required/2`.
  defp trim(nil), do: nil
  defp trim(value), do: String.trim(value)
end
