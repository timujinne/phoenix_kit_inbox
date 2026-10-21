# PhoenixKitInbox

[![Elixir](https://img.shields.io/badge/Elixir-~%3E_1.18-4B275F)](https://elixir-lang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Internal mailbox for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit) — a webmail-shaped inbox for messages between the users of your application. Personal and shared mailboxes, folders, compose/reply/forward, drafts, per-recipient read state, and an admin UI that looks like the mail client your users already know.

## What it is, and isn't

Inbox is **internal**. Messages are addressed to mailboxes inside your application, stored in your database, and read in your admin UI. Nothing is fetched over IMAP and nothing is relayed to the outside world.

What it *can* do, when the host also runs [`phoenix_kit_emails`](https://github.com/BeamLabEU/phoenix_kit_emails), is send a short "you have a new message" nudge to a recipient's real email address so they know to come look. That's a **soft** integration — `phoenix_kit_emails` is not in this package's `mix.exs`, the call is guarded with `Code.ensure_loaded?/1`, and the whole thing is off by default behind a setting.

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
- **Attachments** — uploads, existing Storage files and forwards, each kept as a snapshot in the module's own hidden Storage library and downloaded only by the people on the message
- **Markdown bodies** — written in Markdown, shown through core's email renderer: sanitized, `http(s)`/`mailto` links only, remote images shown as links and never loaded, `{{x}}` left as typed
- **Signatures** — per mailbox, Markdown, one default; put at the end of a message after a `-- ` line and swapped while untouched
- **Sending identities and Reply-To** — who a message may go out *as* (a mail integration whose login is the From address) and which addresses replies may go to, both checked on every send. Stored and resolved here; sending outside the application is not part of this release
- **Mail settings** — "Mail" and "Mail settings" in the avatar menu on every page; an admin page for shared senders and signatures
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

Then enable **Inbox** on the admin Modules page (or call `PhoenixKitInbox.enable_system/0`). The tab appears in the sidebar; routes are generated at compile time from `admin_tabs/0`.

## Data model

Seven tables. The split that matters is **message vs. delivery**: a message body is stored once, and each recipient mailbox gets its own delivery row carrying that mailbox's folder/seen/starred state. It's how every webmail works, and it's why "mark as read" doesn't leak across recipients.

```
phoenix_kit_inbox_mailboxes          one per user (kind: "user") + shared ones (kind: "shared")
 └─ phoenix_kit_inbox_mailbox_grants who may read/write/administer a mailbox they don't own

phoenix_kit_inbox_messages           subject, body, thread_uuid, parent_uuid, sender  (stored ONCE)
 ├─ phoenix_kit_inbox_deliveries     one row per recipient mailbox: folder, seen_at, starred
 └─ phoenix_kit_inbox_attachments    one row per attached file: a reference, not the bytes

phoenix_kit_inbox_identities         sending identities: an email integration + the name shown
phoenix_kit_inbox_signatures         a mailbox's signatures (Markdown), at most one default
```

All primary keys are UUIDv7 and every schema carries `use PhoenixKit.SchemaPrefix`, so named-schema (`--prefix`) installs work.

## Migrations live here, not in core

Older PhoenixKit modules shipped their DDL inside core's versioned chain (the V90+ scheme). Inbox follows the newer pattern already used by `phoenix_kit_boards`, `phoenix_kit_web_analytics`, `phoenix_kit_legal`, and `phoenix_kit_stats`:

- `PhoenixKitInbox.Migrations` is the coordinator, returned from `migration_module/0`
- `PhoenixKitInbox.Migrations.V01` creates the tables; `V02` makes a user's deletion keep their mailboxes and every message (owner `ON DELETE SET NULL`, mailbox references `RESTRICT`) and makes shared addresses unique regardless of case; `V03` adds message attachments; `V04` adds sending identities and mailbox signatures. Shipped versions are immutable
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
Identities.resolve(scope, identity_uuid)   #=> {:ok, %{integration_uuid, from_address, from_name, kind, …}}
                                           #   | {:error, :forbidden | :broken | :not_found}
Identities.resolve(scope, identity_uuid, from_mailbox)  # also {:error, :identity_not_for_mailbox}
Identities.reply_to_options(scope, mailbox) #=> [%{address, label, default}]
```

The From **address** is never typed: it is the login (SMTP username) of the integration, which must be a mail provider (`:email_send` capability) with credentials. A **shared** identity uses a system integration and is managed by holders of `inbox.manage_shared`; bound to a shared mailbox, everyone with `write` on it uses it from there; bound to none, it is the common sender for personal mailboxes, for holders of `inbox.send_external`, and sends as `"<user name> | <from_name>"`. A **personal** identity uses the owner's own integration and only their personal mailbox. Every resolve (use `resolve/3` for a send) checks the integration again; one that is gone, disconnected, not a mail provider, owned by someone else or has no login address marks the identity `broken` and is refused, until it works again. The settings pages show the stored status and check on demand (`Identities.recheck/2`).

Reply-To choices are the user's own email and the address of every shared mailbox they can write to; the default is the sending shared mailbox's address (none if it has no address), or for the personal mailbox the user's saved choice (`Identities.set_default_reply_to/2`), else their email.

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

Every file becomes a **snapshot** in the module's hidden Storage library (slug `phoenix-kit-inbox`, created on first use): it isn't listed in Media, has no permanent URL, and doesn't change when the file it was copied from is edited or deleted. A file gets in as an upload in compose (kept in the browser session's temporary upload until the draft is saved or the message sent — an abandoned compose stores nothing), a Storage file the sender may read, a file the host vouched for (`attachments_authorized:`), bytes the host made (`attachments_data:`), or a forward of a file on a message the sender sent or still has a copy of. Trashed and system-managed files are refused; anything else is `{:error, {:attachment_forbidden, uuid}}`. At most 50 files per message, each up to `inbox_max_upload_bytes`.

"Attach existing file" is core's media picker, limited to the user's own Media files (`UserMediaSelectorModal`); a system role (Owner, Admin) browses the whole library. Each pick is still checked, and a refused file is named only when the user may read it. A file uploaded *inside* the picker lands in Media first (as the picker does everywhere) and is snapshotted at send.

**Requires** a PhoenixKit core with hidden system libraries (core #949) and `Storage.store_file_in_buckets/7` `dedup: false` — the first release after 2.63.0. On an older core every attachment is refused with `{:error, :storage_unsupported}` (logged); messages without attachments work as before.

Downloads go through the module's own route, `GET /admin/inbox/files/:attachment_uuid` (`route_module/0`), behind core's admin pipeline: the sender and anyone holding a non-deleted copy of the message get the file as a download, everyone else a 404.

`flags` are set only by server code and copied on forward. A host that must keep some files away from some people sets a policy:

```elixir
config :phoenix_kit_inbox, attachment_policy: {MyApp.Inbox, :check_attachments}
# (scope, users, attachment_rows) -> :ok | {:error, reason}
```

It is asked on every send and forward carrying attachments about everyone who will be able to read them (the users of the To/Cc/Bcc mailboxes, the owner and grantees of every shared mailbox involved — the sending one included — and the sender too unless every file is a snapshot they created themselves), on a draft save about that mailbox's readers (and its author, by the same rule), and at every download about the viewer alone unless the viewer created the snapshot — so a reader granted a mailbox later is covered, and a forward or a draft cannot pass a file on to someone the policy refuses. Anything but `:ok`, a raise included, refuses; at download that is a 404.

Snapshots are stored before the message's transaction and deleted if it rolls back. A process killed between the two leaves its snapshots in the library with nothing naming them (Storage's orphan cleanup skips hidden libraries), and rolling back to before V03 drops the attachment rows but not the snapshots; neither is swept by the module yet.

The older `send_message(from_mailbox, sender_user_uuid, attrs)` form refuses attachments with `{:error, :attachments_need_scope}`.

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
| `inbox_email_nudges_enabled` | `false` | Send a "new message" email to recipients — needs `phoenix_kit_emails` |
| `inbox_max_upload_bytes` | `200000000` | Largest attachment accepted, in bytes |

```elixir
PhoenixKitInbox.set_email_nudges(true)
PhoenixKitInbox.Notify.email_nudges_available?()  #=> is phoenix_kit_emails actually installed?
```

## Permissions

The module key is `"inbox"`. Two levels:

1. **Module permission** — `Scope.has_module_access?(scope, "inbox")` decides who can open Inbox at all. Managed in the admin roles/permissions matrix like every other module. Two sub-permissions add capabilities, checked by the context functions with `Scope.can?/2`: `inbox.manage_shared` (create shared mailboxes, set addresses, manage shared senders and shared-mailbox signatures) and `inbox.send_external` (use the common sender for personal mailboxes; sending itself is a later release).
2. **Mailbox grants** — decide which mailboxes a user sees once inside, and what they may do there (every function that changes something takes the caller's scope and checks both gates itself). Owning a mailbox implies `"admin"` on it; everything else needs a row in `phoenix_kit_inbox_mailbox_grants`.

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
| `/admin/inbox/mailboxes` | `Web.MailboxesLive` — shared mailboxes and grants |
| `/admin/inbox/settings` | `Web.SettingsLive` — shared senders, shared-mailbox signatures (`inbox.manage_shared`) |
| `/dashboard/inbox-settings` | `Web.MySettingsLive` — the user's signatures, default Reply-To, personal senders; a route core generates from `user_dashboard_tabs/0`, reached from the avatar menu ("Mail settings", next to "Mail" → `/admin/inbox`) |
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
