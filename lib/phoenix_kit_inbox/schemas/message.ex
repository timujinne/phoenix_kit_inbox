defmodule PhoenixKitInbox.Schemas.Message do
  @moduledoc """
  The message body — stored **once**, regardless of how many mailboxes receive
  it. Per-recipient state (which folder it's in, whether it's been read,
  starred, trashed) lives on `PhoenixKitInbox.Schemas.Delivery`, one row per
  recipient mailbox.

  This is the same split Gmail and every other webmail uses, and it's why
  "mark as read in my mailbox" doesn't mark it read for the four other people
  on the thread.

  ## Threading

  `thread_uuid` groups a conversation. A brand-new message gets
  `thread_uuid == uuid` (it *is* the root); a reply inherits the parent's
  `thread_uuid` and sets `parent_uuid`. That's enough for
  `Messages.list_thread/2` to return a conversation in one indexed query, and
  it leaves room for a threaded reading pane later without a migration.

  ## Drafts

  A draft is a message with `status: "draft"` and no `sent_at`. It gets exactly
  one delivery row — into the author's own `"drafts"` folder. Sending flips
  `status` to `"sent"`, stamps `sent_at`, and fans out the recipient deliveries.

  Tables are created by `PhoenixKitInbox.Migrations`, never by this schema.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(draft sent deleted)
  @body_formats ~w(text html markdown)

  @type t :: %__MODULE__{}

  schema "phoenix_kit_inbox_messages" do
    field(:thread_uuid, UUIDv7)
    field(:parent_uuid, UUIDv7)
    field(:sender_mailbox_uuid, UUIDv7)
    field(:sender_user_uuid, UUIDv7)
    field(:subject, :string)
    field(:body, :string)
    field(:body_format, :string, default: "text")
    field(:status, :string, default: "draft")
    field(:sent_at, :utc_datetime)
    field(:metadata, :map, default: %{})

    # Set on what `Messages.send_message/4` returns: `:pending` while the
    # email to external recipients is still to go, `:none` without any.
    # `nil` on a message read back from the database.
    field(:external_status, :any, virtual: true)

    timestamps(type: :utc_datetime)
  end

  @doc "Valid values for the `status` column."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Valid values for the `body_format` column."
  @spec body_formats() :: [String.t()]
  def body_formats, do: @body_formats

  @doc """
  Changeset for creating or updating a draft.

  Deliberately lenient about `subject`/`body`: an empty draft is a legitimate
  thing to autosave. `sent_changeset/2` is where the real requirements land.
  """
  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :thread_uuid,
      :parent_uuid,
      :sender_mailbox_uuid,
      :sender_user_uuid,
      :subject,
      :body,
      :body_format,
      :status,
      :sent_at,
      :metadata
    ])
    |> validate_required([:sender_mailbox_uuid, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:body_format, @body_formats)
    |> validate_length(:subject, max: 500)
  end

  @doc """
  Changeset applied at send time. A sent message must carry a subject or a
  body — an entirely blank message is never worth delivering to anyone.
  """
  def sent_changeset(message, attrs) do
    message
    |> changeset(attrs)
    |> put_change(:status, "sent")
    |> validate_content_present()
  end

  defp validate_content_present(changeset) do
    subject = changeset |> get_field(:subject) |> blank_to_nil()
    body = changeset |> get_field(:body) |> blank_to_nil()

    if is_nil(subject) and is_nil(body) do
      add_error(changeset, :body, "message must have a subject or a body")
    else
      changeset
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
