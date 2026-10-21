defmodule PhoenixKitInbox.Schemas.ExternalRecipient do
  @moduledoc """
  One address outside the application a message went to, and how that went.

  `status` is `"pending"` from the send's transaction until the external
  part has run, then `"sent"` or `"failed"` (with `error`). All external
  recipients of a message travel in one email, so they share their outcome.
  `email_log_message_id` is the `message_id` of the `phoenix_kit_email_logs`
  row, when the host runs `phoenix_kit_emails`. A `"bcc"` row is shown to
  the sending mailbox only.

  Tables are created by `PhoenixKitInbox.Migrations`, never by this schema.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @roles ~w(to cc bcc)
  @statuses ~w(pending sent failed)

  @type t :: %__MODULE__{}

  schema "phoenix_kit_inbox_external_recipients" do
    field(:message_uuid, UUIDv7)
    field(:role, :string)
    field(:address, :string)
    field(:name, :string)
    field(:status, :string, default: "pending")
    field(:error, :string)
    field(:email_log_message_id, :string)
    field(:attempted_at, :utc_datetime)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Valid values for `role`."
  @spec roles() :: [String.t()]
  def roles, do: @roles

  @doc "Valid values for `status`."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses
end
