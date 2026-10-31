# PhoenixKitInbox

[![Elixir](https://img.shields.io/badge/Elixir-~%3E_1.18-4B275F)](https://elixir-lang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Internal mailbox for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit) — a webmail-shaped inbox for messages between the users of your application. Personal and shared mailboxes, folders, compose/reply/forward, drafts, per-recipient read state, and an admin UI that looks like the mail client your users already know.

## What it is, and isn't

Inbox is **internal** first. Messages are addressed to mailboxes inside your application, stored in your database, and read in your admin UI. Nothing is fetched over IMAP.

A message can also go to **email addresses outside** the application — through a mail integration chosen as its sending identity, closed by default and always through a filter the host configures (see [External recipients](#external-recipients)). The same path carries the optional "you have a new message" nudge to a recipient's real address. When the host also runs [`phoenix_kit_emails`](https://github.com/BeamLabEU/phoenix_kit_emails), every such email is in its log; that package stays a **soft** dependency — not in this package's `mix.exs`.

Neighbouring modules, so you pick the right one:

| You want | Use |
|---|---|
| Users messaging each other in-app | **this module** |
| Outbound campaigns / mailing lists | `phoenix_kit_newsletters` |
| Delivery tracking, bounces, SES/SQS | `phoenix_kit_emails` |
| Customer tickets with statuses and SLAs | `phoenix_kit_customer_support` |

## Features

- **Personal mailboxes** — one per user, created lazily on first visit; no signup hook, works for users who predate the install
- **Shared mailboxes** — `support@`, `sales@`, … with per-user `read` / `write` / `admin` grants
- **Six folders** — Inbox, Sent, Drafts, Spam, Trash, Archive
- **Per-recipient state** — seen/unseen, starred, and folder are per mailbox, so marking a group thread read doesn't mark it read for everyone else
- **Compose, reply, forward** — with quoted bodies, `Re:`/`Fwd:` subjects, and inherited threading
- **Drafts** — saved as real messages and *promoted* on send, so the uuid stays stable
- **Search** — case-insensitive over subject and body
- **Threading** — replies carry their root's `thread_uuid`; `list_thread/1` returns a conversation in one indexed query
- **Attachments** — uploads, existing Storage files and forwards, each kept as a snapshot in the module's own Storage library (shown in Media, read-only, and filed in folders) and downloaded only by the people on the message
- **Markdown bodies** — written in Markdown, shown through core's email renderer: sanitized, `http(s)`/`mailto` links only, remote images shown as links and never loaded, `{{x}}` left as typed
- **Signatures** — per mailbox, Markdown, one default; put at the end of a message after a `-- ` line and swapped while untouched
- **Sending identities and Reply-To** — who a message may go out *as* (a mail integration whose login is the From address) and which addresses replies may go to, both checked on every send
- **External recipients** — email addresses in To/Cc/Bcc next to internal ones: one email through the sender's integration after the message is committed, real attachments up to a size limit, a status per address, a retry that never sends twice
- **Mail settings** — "Mail" and "Mail settings" in the avatar menu on every page; a "Mail" page in the admin Settings section for the shared senders (added, changed, opened to roles); a shared mailbox's signatures are written by its row on the Mailboxes page
- **Notifications** — new messages raise an activity event, which core turns into an in-app notification with a deep link
- **Module-owned migrations** — tables ship and version here, not in core
- **Auto-discovery** — implements `PhoenixKit.Module`; PhoenixKit finds it at startup with zero config

## Installation

```elixir
def deps do
  [
    {:phoenix_kit_inbox, "~> 0.2"}
  ]
end
```

```bash
mix deps.get
mix phoenix_kit.update   # generates + runs the host migration for this module
```

Then enable **Inbox** on the admin Modules page (or call `PhoenixKitInbox.enable_system/0`). The tab appears in the sidebar as **Mail** (with "Inbox" and "Mailboxes" under it; the shared-mail settings are a "Mail" page under Settings, for `inbox.manage_shared`); routes are generated at compile time from `admin_tabs/0`.

## Data model

Seven tables. The split that matters is **message vs. delivery**: a message body is stored once, and each recipient mailbox gets its own delivery row carrying that mailbox's folder/seen/starred state. It's how every webmail works, and it's why "mark as read" doesn't leak across recipients.

```
phoenix_kit_inbox_mailboxes          one per user (kind: "user") + shared ones (kind: "shared")
 └─ phoenix_kit_inbox_mailbox_grants who may read/write/administer a mailbox they don't own

phoenix_kit_inbox_messages           subject, body, thread_uuid, parent_uuid, sender  (stored ONCE)
 ├─ phoenix_kit_inbox_deliveries     one row per recipient mailbox: folder, seen_at, starred
 └─ phoenix_kit_inbox_attachments    one row per attached file: a reference, not the bytes

phoenix_kit_inbox_identities         sending identities: an email integration + the name shown
 └─ phoenix_kit_inbox_identity_roles the roles a common sender (shared, no mailbox) is open to
phoenix_kit_inbox_signatures         a mailbox's signatures (Markdown), at most one default
```

All primary keys are UUIDv7 and every schema carries `use PhoenixKit.SchemaPrefix`, so named-schema (`--prefix`) installs work.

## Migrations live here, not in core

Older PhoenixKit modules shipped their DDL inside core's versioned chain (the V90+ scheme). Inbox follows the newer pattern already used by `phoenix_kit_boards`, `phoenix_kit_web_analytics`, `phoenix_kit_legal`, and `phoenix_kit_stats`:

- `PhoenixKitInbox.Migrations` is the coordinator, returned from `migration_module/0`
- `PhoenixKitInbox.Migrations.V01` creates the tables; `V02` makes a user's deletion keep their mailboxes and every message (owner `ON DELETE SET NULL`, mailbox references `RESTRICT`) and makes shared addresses unique regardless of case; `V03` adds message attachments; `V04` adds sending identities and mailbox signatures; `V05` external recipients with their status; `V06` the roles of a common sender, given on the update to the roles holding `inbox.send_external` or `"*"` (Owner aside); `V07` links from messages to objects of the host, idempotent send keys, and a shared identity's sender-name flag. Shipped versions are immutable
- Version is tracked in a `COMMENT ON TABLE` on `phoenix_kit_inbox_mailboxes`, so the coordinator can tell "not installed" from "installed at V1"
- `mix phoenix_kit.update` discovers the coordinator, compares versions, and generates the host migration

Nothing has to be released in `phoenix_kit` for this module's schema to change.

### Adding a version

1. Write `lib/phoenix_kit_inbox/migrations/vNN.ex` with `up/1` and `down/1`
2. Bump `@current_version` in `PhoenixKitInbox.Migrations` and add the `apply_step/3` clauses for it
3. **Never edit a shipped version module** — hosts already past it will not re-run it

New SQL must stay prefix-safe: bare index names on `CREATE`, schema-anchored existence checks, `Helpers.uuid_v7_call/1` for the UUID default. See core's AGENTS.md, "Prefix-safe migrations".

## Usage

### Mailboxes

```elixir
alias PhoenixKitInbox.Mailboxes

# Personal mailbox — created on first call, returned thereafter
{:ok, mailbox} = Mailboxes.ensure_user_mailbox(current_user)

# Shared mailbox + grants — needs inbox.manage_shared on the caller's scope
{:ok, support} = Mailboxes.create_shared_mailbox(scope, %{
  name: "Customer Support",
  address: "support@example.com"
})

{:ok, _} = Mailboxes.grant_access(scope, support, teammate.uuid, "write")   # admin on support
Mailboxes.search_users(me.uuid, "ann")                #=> [%{uuid, name, username}] — members, not me
Mailboxes.list_grant_holders(support.uuid)            #=> [%{user_uuid, access, name, username}]

Mailboxes.access_level(support, owner.uuid)           #=> "admin"  (ownership implies admin)
Mailboxes.authorize(support, teammate.uuid, "write")  #=> :ok
Mailboxes.list_accessible_mailboxes(user.uuid)        #=> personal first, then shared
```

### Sending

```elixir
alias PhoenixKitInbox.Messages

{:ok, message} = Messages.send_message(scope, from_mailbox, %{
  "to" => "@bob, support",              # @username, email, or shared mailbox; comma separated
  "cc" => "carol@example.com",
  "subject" => "Quarterly numbers",
  "body" => "Attached below."
})
```

The sender needs `write` on `from_mailbox` and, in the scope form, the `"inbox"` permission. The older `send_message(from_mailbox, sender_user_uuid, attrs)` form still works and checks the same grant.

The whole send is one `Ecto.Multi`: recipients resolve, the message is written, and deliveries fan out — or none of it happens. A recipient that doesn't resolve fails the send with `{:error, {:unknown_recipients, ["typo@example.com"]}}` rather than being silently dropped; a term naming two people fails with `{:error, {:ambiguous_recipients, [...]}}`.

Only **members** can be addressed or suggested: by default a user any of whose roles carries `"inbox"` or `"*"`, or the Owner. A host replaces the rule with:

```elixir
config :phoenix_kit_inbox, recipient_filter: {MyApp.Inbox, :addressable?}  # (user) -> boolean
```

A recipient's in-app notification links to the message in their mailbox, with the host's URL prefix and the reader's locale applied. A host whose readers may not open the Inbox pages sends them elsewhere, per reader: the function returns the path the browser opens, as given (build it with `PhoenixKit.Utils.Routes.path/2` when the app has a URL prefix or locale segments), or `nil` for the module's link. The email nudge still links to the Inbox pages, so such a host keeps nudges off; see `PhoenixKitInbox.Notify`.

```elixir
config :phoenix_kit_inbox, notification_link: {MyApp.Inbox, :notification_link}  # (message, mailbox, reader_uuid) -> "/path" | nil
```

Each send records a snapshot of the sender and recipients in the message's `metadata` and one permanent `inbox.message_sent` activity (counts only).

A message may name a sending identity and a Reply-To; both are checked against the sender's scope and the sending mailbox, and recorded in `metadata["identity"]` / `metadata["reply_to"]` (a caller's `metadata` can't set them). Nothing leaves the application because of them yet:

```elixir
Messages.send_message(scope, from_mailbox, %{
  "to" => "@bob", "subject" => "Hi", "body" => "**Hello**", "body_format" => "markdown",
  "identity_uuid" => identity_uuid,     # {:error, {:identity_unusable, :forbidden | :broken | …}}
  "reply_to" => "support@example.com"   # {:error, :reply_to_not_allowed} unless offered below
})
```

### Sending identities

```elixir
alias PhoenixKitInbox.Identities

Identities.list_usable(scope)              #=> [%{identity_uuid, label, kind, from_address, from_name, …}]
Identities.list_usable(scope, mailbox)     # only those a message from `mailbox` may go out as
Identities.resolve(scope, identity_uuid)   #=> {:ok, %{integration_uuid, from_address, from_name, kind, …}}
                                           #   | {:error, :forbidden | :broken | :not_found}
Identities.resolve(scope, identity_uuid, from_mailbox)  # also {:error, :identity_not_for_mailbox}
Identities.reply_to_options(scope, mailbox) #=> [%{address, label, default}]
```

The From **address** is never typed: it is the login (SMTP username) of the integration, which must be a mail provider (`:email_send` capability) with credentials. A **shared** identity uses a system integration and is managed by holders of `inbox.manage_shared`; bound to a shared mailbox, everyone with `write` on it uses it from there; bound to none, it is the common sender for personal mailboxes, for holders of `inbox.send_external` with one of its roles in effect, and sends as `"<user name> | <from_name>"`. A **personal** identity uses the owner's own integration and only their personal mailbox. Every resolve (use `resolve/3` for a send) checks the integration again; one that is gone, disconnected, not a mail provider, owned by someone else or has no login address marks the identity `broken` and is refused, until it works again. The settings pages show the stored status and check on demand (`Identities.recheck/2`).

#### Shared mail and its roles

A common sender is "shared mail": people send *as* it, nobody reads it through the module. Each one has its own list of roles, kept with the identity:

```elixir
Identities.create_shared(scope, %{"label" => "Company", "integration_uuid" => uuid,
                                  "role_uuids" => [sales_role_uuid]})
Identities.update_identity(scope, identity, %{"role_uuids" => []})   # open to nobody (but Owner)
Identities.list_shared(scope)    #=> [%{identity, from_address, roles: [%{uuid, name}]}]
Identities.role_choices(scope)   #=> [%{uuid, name, sends_external}] — every role but Owner
```

The roles only narrow: using one still needs `inbox.send_external`, and one of the roles **in effect** for the scope (a user acting as one of their roles has that one only) must be on its list; Owner may always use it and is never on a list. Owner, `nil` and unknown uuids in `"role_uuids"` are dropped; `create_shared/2` without the key opens the sender to the roles holding `inbox.send_external` or `"*"`. A role that does not itself give `inbox.send_external` may be on a list — the right is the user's. The list is read on every send, in the task after the commit and on a retry, so a role taken off stops what has not gone yet. A sender bound to a shared mailbox has no roles (it goes by the mailbox); the email nudge ignores them. Someone with `inbox.send_external` and no sender open to them for the sending mailbox gets `{:error, :external_not_allowed}` on an external address.

Reply-To choices are the user's own email and the address of every shared mailbox they can write to; the default is the sending shared mailbox's address (none if it has no address), or for the personal mailbox the user's saved choice (`Identities.set_default_reply_to/2`), else their email.

### External recipients

```elixir
{:ok, message} = Messages.send_message(scope, from_mailbox, %{
  "to" => "@bob, client@example.com",       # internal and external at once
  "bcc" => "archive@example.com",
  "identity_uuid" => identity_uuid,         # required for external addresses
  "body" => "**Offer** attached", "body_format" => "markdown"
})
message.external_status                     #=> :pending (:none without external recipients)

Messages.list_external_recipients(message.uuid, viewer_mailbox_uuid)  # Bcc only for the sender
External.display_status(row)                #=> :pending | :sent | :failed | :unknown
External.subscribe(from_mailbox.uuid)       # {:inbox_external_updated, message_uuid}
Messages.retry_external(scope, from_mailbox, message.uuid)            #=> {:ok, :pending}
```

An email address that names no member and no shared mailbox is an external recipient — if the sender may write externally (`inbox.send_external`, or sending as their own personal identity); otherwise it is an unknown recipient, as before; the three-argument `send_message/3` refuses it (`{:error, :external_needs_scope}`). External recipients need a sending identity (`{:error, :external_needs_identity}`) and external sending **open**:

```elixir
PhoenixKitInbox.set_external_enabled(true)          # inbox_external_enabled, off by default
config :phoenix_kit_inbox, outbound_filter: {MyApp.Inbox, :outbound}   # or :none, explicitly
```

Without both, `{:error, :external_disabled}`. Every email the module sends — a message, its retry, a nudge — goes through `PhoenixKitInbox.Outbound.deliver/2`: the filter gets the `%Swoosh.Email{}` and a context (kind, integration, sender, message) and returns `{:ok, email}` — of which To, Cc, Bcc and Reply-To are taken, so a staging host can redirect everything to a test address — or `{:error, reason}`; a raise, throw or any other answer refuses. Then core's `PhoenixKit.Mailer.deliver_via_integration/3` through the identity's integration, always with `skip_queue: true` and `queue: false` (a queued message would be re-sent through core's *default* integration), `user_uuid`, `integration_uuid` and `message_tags: %{"source" => "inbox", "inbox_message_uuid" => …, "inbox_kind" => "message" | "nudge"}`.

The message, its deliveries and its external recipients (`pending`) are written in one transaction; the email goes after the commit, in a task under the module's `PhoenixKitInbox.TaskSupervisor`, and the rows become `sent` or `failed`. A failure there never touches the internal part. A row still pending after 15 minutes reads as `:unknown` — check the email log. The body is the Markdown rendered as in the reading pane, plus a plain-text part; attachments travel as real attachments, read from Storage, up to `inbox_external_max_bytes` in total as base64 (25 MB by default) — a larger message is refused before anything is stored.

**Retry** re-sends the failed rows, from the sending mailbox only, with the identity and the right to write externally checked again, and only when `phoenix_kit_emails` runs and every log row of the message's email is `failed` or `rejected`; the rows are taken in one statement, so two retries at once send one email.

A host that sent an email itself records it in the sender's Sent folder:

```elixir
Messages.record_sent(scope, mailbox, %{
  "subject" => "Offer 12", "body" => "…",
  "external_recipients" => [%{"address" => "client@example.com", "status" => "sent"}],
  "attachments" => [%{"filename" => "offer.pdf", "size_bytes" => 1234}]   # names only, no files
}, host_ref: "send-42")
```

No internal delivery (an internal address is `{:error, {:internal_recipients, …}}`), no outbound mail, no stored files, no retry; `metadata["source"] == "host"`.

### Signatures

```elixir
alias PhoenixKitInbox.Signatures

Signatures.list(mailbox_uuid)                       # default first
{:ok, sig} = Signatures.create_signature(scope, mailbox, %{"label" => "Work", "body" => "**Ann**", "is_default" => true})
Signatures.swap_block(body, previously_inserted_block, new_signature)  #=> {:ok, body} | :edited
```

A personal mailbox's signatures are its owner's; a shared mailbox's need `admin` on it and `inbox.manage_shared`.

### Reading and filing

```elixir
Messages.list_folder(mailbox.uuid, "inbox", limit: 50, search: "invoice", unseen_only: true)
Messages.count_folder(mailbox.uuid, "inbox")
Messages.fetch_for_mailbox(mailbox.uuid, message_uuid)   # scoped — never reads someone else's mail
Messages.list_thread(message.thread_uuid)

Messages.mark_seen(scope, mailbox, message_uuid)        # read on the mailbox
Messages.toggle_star(scope, mailbox, message_uuid)      # read
Messages.move_to_folder(scope, mailbox, message_uuid, "archive")   # write
Messages.purge(scope, mailbox, message_uuid)   # write; removes only THIS mailbox's copy
```

### Attachments

```elixir
{:ok, message} = Messages.send_message(scope, from_mailbox, %{
  "to" => "@bob",
  "subject" => "Drawings",
  "attachments" => [%{"file_uuid" => file.uuid}]   # a Storage file the sender may read
}, attachments_authorized: [checked_file_uuid],     # server-side only: the host checked it
   attachment_flags: %{checked_file_uuid => %{"reviewed" => true}},
   attachments_data: [%{binary: pdf, filename: "offer.pdf", content_type: "application/pdf"}])

Attachments.list_for_message(message.uuid)   #=> [%Attachment{filename: …, file_uuid: …, flags: …}]
Paths.attachment(attachment.uuid)            #=> "/admin/inbox/files/<uuid>"
```

Every file becomes a **snapshot** in the module's Storage library (slug `phoenix-kit-inbox`, created on first use): a record of its own that has no permanent URL and doesn't change when the file it was copied from is edited or deleted. Its stored objects may be the same ones as the original's (the core's `Storage.link_copy/3`, where it has it), so a snapshot of a file already in Media costs no second copy of the bytes. A file gets in as an upload in compose (kept in the browser session's temporary upload until the draft is saved or the message sent — an abandoned compose stores nothing), a Storage file the sender may read, a file the host vouched for (`attachments_authorized:`), bytes the host made (`attachments_data:`), or a forward of a file on a message the sender sent or still has a copy of. Trashed and system-managed files are refused; anything else is `{:error, {:attachment_forbidden, uuid}}`. At most 50 files per message, each up to `inbox_max_upload_bytes`.

"Attach existing file" is core's media picker, limited to the user's own Media files (`UserMediaSelectorModal`); a system role (Owner, Admin) browses the whole library. Each pick is still checked, and a refused file is named only when the user may read it. A file uploaded *inside* the picker lands in Media first (as the picker does everywhere) and is snapshotted at send.

**Requires** a PhoenixKit core with hidden system libraries (core #949) and `Storage.store_file_in_buckets/7` `dedup: false` — core 2.64.0 or later, which `mix.exs` requires. On an older core every attachment is refused with `{:error, :storage_unsupported}` (logged); messages without attachments work as before. A core that also has `Storage.link_copy/3` shares objects instead of copying (for uploads and host bytes it looks for a donor by checksum in Media, which has no index on `file_checksum`: the cost grows with Media), and one with managed libraries shows the library in Media (below); each is used when it is there.

Downloads go through the module's own route, `GET /admin/inbox/files/:attachment_uuid` (`route_module/0`), behind core's admin pipeline: the sender and anyone holding a non-deleted copy of the message get the file as a download, everyone else a 404.

`flags` are set only by server code and copied on forward. A host that must keep some files away from some people sets a policy:

```elixir
config :phoenix_kit_inbox, attachment_policy: {MyApp.Inbox, :check_attachments}
# (scope, users, attachment_rows) -> :ok | {:error, reason}
```

It is asked on every send and forward carrying attachments about everyone who will be able to read them (the users of the To/Cc/Bcc mailboxes, the owner and grantees of every shared mailbox involved — the sending one included — and the sender too unless every file is a snapshot they created themselves), on a draft save about that mailbox's readers (and its author, by the same rule), and at every download about the viewer alone unless the viewer created the snapshot — so a reader granted a mailbox later is covered, and a forward or a draft cannot pass a file on to someone the policy refuses. Anything but `:ok`, a raise included, refuses; at download that is a 404. The reading pane and compose (a forward, a draft) ask it the same way, per file, and show a refused file as "Attachment not available" — no name, no size, no link (`Attachments.list_for_viewer/2`); without a policy nothing extra is asked.

Snapshots are stored before the message's transaction and deleted if it rolls back, raises or exits. Compose sends and saves in a task, so the page stays responsive while files are copied; a failure leaves the text, the uploads and the attachments in the form, and leaving the page does not stop a send that is under way (unless the module's task supervisor is not running: then the send runs with the page and stops with it). A process killed after storing the snapshots and before the commit leaves its snapshots in the library with nothing naming them (Storage's orphan cleanup skips hidden libraries), and rolling back to before V03 drops the attachment rows but not the snapshots; neither is swept by the module yet.

The older `send_message(from_mailbox, sender_user_uuid, attrs)` form refuses attachments with `{:error, :attachments_need_scope}`.

#### The library in Media

Where the core has managed libraries, the attachments library is **listed in Media** under the name *Mail attachments* and **read-only**: nobody changes, deletes, moves or renames its files there, Owner included — the core refuses it. Files lie in folders: `<mailbox> / <YYYY-MM> / <date time — subject>` for a sent message, `<mailbox> / Drafts` for a draft's new files; a message that names a file already filed elsewhere (a forward) gets a link in its own folder.

```elixir
config :phoenix_kit_inbox, media_listing: :uploaders        # :uploaders (default) | :admins | :own_only | :none
config :phoenix_kit_inbox, library_name: "Mail attachments" # the library's name in Media
config :phoenix_kit_inbox, attachment_folder: {MyApp.Inbox, :attachment_folder}
# (message, sending_mailbox) -> ["Orders", "order-123"] | nil
```

- `media_listing` says who finds the library in Media: `:none` no one (it stays hidden), `:admins` Owner/Admin, `:uploaders` Owner/Admin see every file and any other holder of the `media` permission the files they uploaded, `:own_only` everyone only their own. A library an earlier version made hidden is brought up to date on the first use of a node.
- **Media does not ask `attachment_policy`.** Under `:admins` and `:uploaders` an Owner/Admin sees every attachment of every message, past the policy. A host whose policy hides files from its administrators sets `:own_only` or `:none`. Recipients don't see the files they were sent in Media (they aren't uploaders); they read them in Inbox.
- `attachment_folder` replaces the `<mailbox>/<YYYY-MM>` part: a non-empty list of names, each a non-blank string of at most 255 characters without `/` or control characters. `nil`, any other answer, a raise, exit or throw means the default path (a warning for all but `nil`). It runs in the process that sends, after the commit, so it can read the host's per-request context; Compose's background task and the maintenance task have none, so there the default path is used.
- Folder names carry the message's subject and the mailbox's name; under `:admins` and `:uploaders` an Owner/Admin sees them in Media, past Inbox's own access rules.
- A file is filed with the first sent message that names it. Filing is best effort and never fails a send; whatever it misses stays in the root or in `Drafts` until the task below files it.

##### Moving existing snapshots

Snapshots stored before this (full copies) can be moved onto the objects of an active file that holds the same bytes (a Media file, or a snapshot already on Media's objects), and the messages sent before filed in folders — in two phases, so nothing is deleted before it has been checked. Needs a core with `Storage.relink_file/3` (otherwise the task says so and does nothing):

```bash
mix phoenix_kit_inbox.relink_attachments                                   # dry run: what would be done, writes nothing
mix phoenix_kit_inbox.relink_attachments --apply --manifest relink.json    # phase 1
mix phoenix_kit_inbox.relink_attachments --purge-old --manifest relink.json # phase 2
```

Phase 1 first checks the manifest can be written, then relinks each snapshot that has a donor (same checksum and size, in Media or already on Media's objects) and adds it to the manifest at once (each record's uuid, checksum and old keys, only canonical ones under the library's own key prefix), files every sent message that isn't filed, and reads every relinked file back to compare its sha256 (`"verified": true` only on a match); the old objects stay. A snapshot that doesn't qualify (not active, being edited) or a message whose mailbox is gone is reported as skipped, not as an error. Each record is put on the manifest before it is moved and again after, and a `<manifest>.lock` file keeps two runs apart (delete it by hand after a killed run). A run cut short, or a file that did not read back, is re-checked by running `--apply` again; a record deleted meanwhile is marked `gone`; a file that does not match stays relinked and its old objects are never deleted (unless the record is deleted later, then they go in phase 2 once nothing names them) — restore the dump if it matters. Phase 2 deletes the manifest's old keys that nothing names any more, dropping any key that is not a plain key under the library's prefix (`..` and the like) and every key an unverified entry names. A dry run only reads. Keep the database dump from before phase 1, and copy the library's directory in the bucket before phase 2. A second run changes nothing. The report counts records, relinked, filed, bytes to free and errors; the exit code is 1 when anything failed.

### Drafts

```elixir
{:ok, draft} = Messages.save_draft(scope, mailbox, %{"to" => "@bob", "subject" => "WIP"})
Messages.draft_recipients(draft)   #=> %{"to" => "@bob", "cc" => "", "bcc" => ""}
{:ok, draft} = Messages.save_draft(scope, mailbox, %{"uuid" => draft.uuid, "body" => "more"})

# Sending promotes the same row — same uuid, status flips to "sent"
{:ok, sent} = Messages.send_message(scope, mailbox, %{
  "uuid" => draft.uuid, "to" => "bob@example.com", "subject" => "WIP"
})
```

## Settings

| Key | Default | What it does |
|---|---|---|
| `inbox_enabled` | `false` | Module on/off (the admin Modules page toggle) |
| `inbox_email_nudges_enabled` | `false` | Send a "new message" email to recipients — also needs a nudge sender and external sending open |
| `inbox_nudge_identity_uuid` | none | The shared identity nudges go out from; without one there is no nudge |
| `inbox_external_enabled` | `false` | Allow mail to addresses outside the application — also needs the host's `outbound_filter` |
| `inbox_external_max_bytes` | `26214400` | Largest total of attachments for external recipients, as base64 |
| `inbox_max_upload_bytes` | `200000000` | Largest attachment accepted, in bytes |

```elixir
PhoenixKitInbox.set_email_nudges(true)
PhoenixKitInbox.set_nudge_identity(scope, shared_identity_uuid)   # inbox.manage_shared
PhoenixKitInbox.Notify.email_nudges_available?()  #=> nudge sender set and external sending open?
```

## Permissions

The module key is `"inbox"`. Two levels:

1. **Module permission** — `Scope.has_module_access?(scope, "inbox")` decides who can open Inbox at all. Managed in the admin roles/permissions matrix like every other module. Two sub-permissions add capabilities, checked by the context functions with `Scope.can?/2`: `inbox.manage_shared` (create shared mailboxes, set addresses, manage shared senders and shared-mailbox signatures) and `inbox.send_external` (write to external addresses through a shared sender, including the common sender for personal mailboxes; a personal sender's owner writes externally without it).
2. **Mailbox grants** — decide which mailboxes a user sees once inside, and what they may do there (every function that changes something takes the caller's scope and checks both gates itself). Owning a mailbox implies `"admin"` on it; everything else needs a row in `phoenix_kit_inbox_mailbox_grants`.

Open pages follow changes to both without a reload: a permission change through core's scope refresh (each page exports `phoenix_kit_scope_changed/1`), a grant, archive or sender change through `PhoenixKitInbox.AccessEvents`. A mailbox the user can no longer read is closed for their personal one, a compose form keeps what was typed but falls back to a mailbox, sender and Reply-To still allowed, and the mail settings page sends a user who lost Inbox to their dashboard.

Levels are ordered `read < write < admin`:

| Level | Can |
|---|---|
| `read` | open the mailbox, read, mark seen/starred |
| `write` | the above, plus compose/send as the mailbox, move, trash |
| `admin` | the above, plus manage the mailbox's grants and archive it |

## URLs

All navigation goes through `PhoenixKitInbox.Paths`, never a hardcoded string — the host's URL prefix and locale are applied there.

| Path | LiveView |
|---|---|
| `/admin/inbox` | `Web.InboxLive` — folders, list, reading pane |
| `/admin/inbox?folder=sent&message=<uuid>` | same LiveView, patched |
| `/admin/inbox/compose` | `Web.ComposeLive` (also `?reply_to=`, `?forward=`, `?draft=`) |
| `/admin/inbox/mailboxes` | `Web.MailboxesLive` — shared mailboxes, grants (colleagues picked by name) and each active mailbox's signatures (its admins with `inbox.manage_shared`) |
| `/admin/settings/inbox` | `Web.SettingsLive` — "Mail" in core's Settings section (`settings_tabs/0`): shared senders with their roles (add, edit, check, delete), for `inbox.manage_shared` |
| `/dashboard/inbox-settings` | `Web.MySettingsLive` — the user's signatures, default Reply-To, personal senders, a link to "Shared mail" for `inbox.manage_shared`; a route core generates from `user_dashboard_tabs/0`, reached from the avatar menu ("Mail settings", next to "Mail" → `/admin/inbox`) |
| `/admin/inbox/files/<attachment uuid>` | `Web.AttachmentController` — an attachment download (no locale segment) |

Folder, message, search, and page are query params, not path segments, so the whole mailbox stays one LiveView: switching folders is a `push_patch`, not a remount.

## Local cross-repo development

`phoenix_kit` resolves from Hex by default. To build or test against a local checkout, export `<APP>_PATH`:

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix test
```

Implemented via `pk_dep/3` in `mix.exs` — never hand-edit a `phoenix_kit*` dep into a `path:` tuple, a committed path dep ships a broken package.

## Testing

```bash
mix test.setup   # createdb; the test helper runs core's migrations + ours on every boot
mix test
```

Integration tests auto-exclude via the `:integration` tag when PostgreSQL isn't reachable; unit tests still run. The suite applies this module's migrations through `PhoenixKitInbox.Test.Migration` — the same coordinator a real host runs — so it can't pass against a schema that differs from what installs get.

## Pre-commit

```bash
mix precommit   # compile --warnings-as-errors + deps.unlock --check-unused + hex.audit + format + credo --strict + dialyzer
```

## License

MIT — see [LICENSE](LICENSE).
