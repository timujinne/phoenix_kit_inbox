defmodule PhoenixKitInbox.Web.Components.ComposeDraft do
  @moduledoc """
  The draft a host hands a compose form: everything the host knows about the
  message before the person writes a word, and the one thing the form may
  rely on. It lives on the server — in the host's assigns — and is never sent
  to the browser as a right: what the browser sends back
  (`PhoenixKitInbox.Web.Components.ComposePipeline`) is checked against it.

  ## Fields

    * `:to`, `:cc`, `:bcc` — `[recipient]`, each a map (`t:recipient/0`):
      `%{address: "x@example.com" | "@alice", label: "Anna", route: :email}`
      or `%{user: user_uuid, label: ..., route: :internal}`. `:route` says how
      the host means the message to reach them: `:internal` (inside the
      application) or `:email` (out). The send checks that this is how the
      address really resolves and refuses the message if not
    * `:subject`, `:body`, `:body_format` (`"markdown"` by default; `"text"`
      or `"html"`) — what the person starts from
    * `:attachments` — `[attachment]` the host attaches (`t:attachment/0`),
      files of Storage the host has vouched for, or bytes it made. The person
      may take them away; they cannot be added to
    * `:from` — `:user_default` (the person's own mailbox; with outside
      recipients, the first of their usable identities), `{:mailbox, uuid}` or
      `{:identity, uuid}` (an identity of a shared mailbox, or a personal or
      common one from the person's own mailbox). `:from_editable` — whether
      the person may choose another (`true` by default); when `false`
      whatever the form submits for it is ignored
    * `:reply_to` — the Reply-To address to start from (must be one of
      `Identities.reply_to_options/2`); `:reply_to_trusted` — an address the
      host vouches for, which is also the starting one when present and which
      the person may pick or clear
    * `:links` — `[%{kind: "order", ref: "…"}]`: the objects the message is
      linked to (from the draft only)
    * `:reply_to_message` — the uuid of the message this answers; it gives the
      message its conversation
    * `:idempotency_key` — issued by the form on every opening; a repeated
      send with the same key is one message
    * `:html_body` — the host's ready-made HTML for the email to outside
      recipients; never shown in the form, never read from it
    * `:context` — a map of the host's own, passed through to its recipient
      sources and (with `:links` added) to `authorize_attachments`

  ## Recipient and attachment shapes

  A recipient is `%{address: String.t()}` **or** `%{user: uuid}`, plus
  `:label` (a name, optional) and `:route` (`:internal | :email`; `:email`
  when missing). With `:user` the pipeline works out the text: the user's
  handle for `:internal`, their login email for `:email`.

  An attachment is one of

    * `%{id: "a", file_uuid: uuid, name: "offer.pdf", flags: %{…}}` — a Storage
      file; `flags` is kept with the attachment for the host's own rules
    * `%{id: "b", binary: bytes | path: "/…", filename: "offer.pdf",
      content_type: "application/pdf", flags: %{…}}` — bytes the host made

  `:id` is what the form uses to say "this one stays" (the file uuid by
  default; a position for bytes). `:name` is what is shown.

  ## What the host's wrapper (`around_send/3`) may change

  The pipeline hands the wrapper this struct with the recipients, subject and
  body as the person left them (recipients normalised: `:address` and `:route`
  on every one). Through `send_fun.(draft)` the wrapper may replace
  `:subject`, `:body`, `:html_body` and `:attachments`; everything else it
  changes is ignored.
  """

  @type route :: :internal | :email

  @type recipient :: %{
          optional(:address) => String.t(),
          optional(:user) => binary(),
          optional(:label) => String.t() | nil,
          optional(:route) => route()
        }

  @type attachment :: %{optional(atom()) => term()}

  @type from :: :user_default | {:mailbox, binary()} | {:identity, binary()}

  @type t :: %__MODULE__{
          to: [recipient()],
          cc: [recipient()],
          bcc: [recipient()],
          subject: String.t() | nil,
          body: String.t() | nil,
          body_format: String.t(),
          attachments: [attachment()],
          from: from(),
          from_editable: boolean(),
          reply_to: String.t() | nil,
          reply_to_trusted: String.t() | nil,
          links: [%{kind: String.t(), ref: String.t()}],
          reply_to_message: binary() | nil,
          idempotency_key: String.t() | nil,
          html_body: String.t() | nil,
          context: map()
        }

  defstruct to: [],
            cc: [],
            bcc: [],
            subject: "",
            body: "",
            body_format: "markdown",
            attachments: [],
            from: :user_default,
            from_editable: true,
            reply_to: nil,
            reply_to_trusted: nil,
            links: [],
            reply_to_message: nil,
            idempotency_key: nil,
            html_body: nil,
            context: %{}
end
